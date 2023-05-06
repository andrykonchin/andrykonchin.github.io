---
layout:     post
title:      Deadlock in RSpec
date:       2019-12-25 00:09
categories: Ruby
---

Recently a fix of a bug in RSpec caught my eye ([_pull
request_](https://github.com/rspec/rspec-core/pull/2669)). The issue was
a deadlock of two processes that leads to hanging out. I couldn't pass
by without diving into details - I don't see deadlock every day.

RSpec supports a command line option `--bisect`
([documentation](https://relishapp.com/rspec/rspec-core/docs/command-line/bisect)),
that is useful deal with flacky failing specs. Sometimes spec failure
depends on order of test cased and what cased were run before it (it's
common to run specs suite in rundom order, probably to catch such
things). In this case there is minimal sequence of test cases that
causes a failure of the test case. It's exactly what `--bisect` can help
you with. With this option RSpec reruns specs multiple times decreasing
thier ammount by half and select that half what fails. To do so RSpec
should every time run tests in isolation, that is in a new system
process.

Sometimes launching RSpec with `--bisect` ends up with hanging out. It
was reported for the first time
[here](https://github.com/rspec/rspec-core/issues/2637) by maintaners of
the Puppet project. Moreover they have also investigated the issue and
found out the cause:

> Meanwhile the main process is hanging in waitpid at
>
> Process.waitpid(pid)
>
> A common reason why this might not show up in testing is if the result
> report in the tests is smaller than the underlying OS's buffer size. In
> that case the runner process exits after writing to the buffer and the
> parent continues happily reading from the buffer. In my case the
> testsuite results are ~93kB and the processes deadlock.

Let's figure out what is going on here.


### How `--bisect` does work

RSpec used two diffenent ways to run specs in a separate process - using
*shell*-command, that leans to system calls `fork` + `exec`, or
_forking_ its own process. In both cases new child process is created.
In the first case result of specs running is written into _stdout_, that
is available for the parent process. In the second case for passing data
between child and parent processes RSpec uses system unnamed
[pipe](https://linux.die.net/man/7/pipe). The problem happens only in
the second case with `fork`.

To read and write into a pipe RSpec used blocking operations - the child
process writes into the pipe data, and the parent process is waiting for
the child process stopping and then read from the pipe. Let's look at
this in details.

Blocking reading means, that if you need to read _n_ bytes but a pipe's
buffer contains less bytes then reading operation will wait untill there
are available require amount of bytes.

Blocking writing means, that if you need to write _n_ bytes, but a pop's
buffer doesn't have enough free space (a buffer has fixed and limited
size) then writing operation will wait untill some data is read from a
pipe and there is enough space to write _n_ bytes.

In our case the parent process makes the `waitpid` system call to wait
for the child process terminating. When a process terminates - it
becomes a _zombie_ process - system resources are freed, but a parent
process still doesn't know about a child process termination. A parent
process must get a status of a child process termitation by making the
`waitpid` system call. Only then a child process is completely
disappeared.

Let's illustrate this with a sequence diagram:

<img src="/assets/images/2019-12-25-deadlock-in-rspec/success.svg"/>

The _Parent process_ created a new child process and waits for it
termination. The new process runs specs and writes results into the
_Pipe_. The child process terminates and operation system (_Kernel_)
returns an exit status to the _Parent process_ as result of the
`waitpid` system call. Later the _Parent process_ reads from the _Pipe_
and continues the _bisect_ operation.


### Look at the bug

RSpec hanging out can be reproduced in the [following
way](https://github.com/benoittgt/rspec_repro_bisect_deadlock):

```ruby
RSpec.describe "a bunch of nothing" do
  (0...3000).each do |t|
    it { expect(t).to eq t }
  end
end
```

Command `--bisect` will hang out every time.

The way RSpec runs specs in a child process and passing results back to
a parent process looks roughtly this way:

```ruby
@read_io, @write_io = IO.pipe

# write into pipe some data
def run_specs
  packet = '*' * 1000
  @write_io.write("#{packet.bytesize}\n#{packet}")
end

# create a child process
pid = fork { run_specs }

# wait for its terminating
Process.waitpid(pid)

# read result
packet_size = Integer(@read_io.gets)
packet = @read_io.read(packet_size)

puts "packet size: #{packet.size}"
```

Here we create a pipe and two `IO` objects to write (`@write_io`) and to
read (`@read_io`) the pipe. Then a new child process is created with
calling method `fork`, that executes a passed block. The child process
inherits all the file descriptors of the parent process, so the pipe's
descriptors as well. The method `run_specs` is called in the child
process and writes some bytes (1000 characters, that means 1000 bytes)
into the pipe. The parent process after forking the child process waits
for a child process termination (calling the method `waitpid`) and then
reads from the pipe.

If run this code then data transfering works without any issue and a
message "packet size: 1000" will be printed to the terminal.

But if increase bytes number from 1000 to 66000 (it means the child
process will write back not 1000 bytes byt 66000) then RSpec will hang
out.

The reason is pretty obvious - a pipe's buffer has a limitted size. If
you are trying to write to a pipe more bytes than free space in a
buffer, then a blocking writing will be blocked and waiting untill some
data are read from a buffer and there is enough free space to write all
the bytes. But nobody reads from the pipe. The parent process will read
but only after the child process termination. The child process cannot
terminate, because cannot write the rest bytes into the pipe. To
reprodice the issue bytes number (66000) to write should be greated than
the pipe buffer.

This situation is illustrated with the following diagram:

<img src="/assets/images/2019-12-25-deadlock-in-rspec/deadlock.svg"/>

Both processes made blocking method calls (writing to the pipe and
waiting for the child process termination) and are deadlocked.

This way, if RSpec in the child process writes to _stdout_ less than
64KB then the issue isn't reproduced. But if more than 64KB then
deadlock happens and RSpec hangs out.


### Pipe's buffer size

A pipe buffer size is defined neither by POSIX standard nor operation
system documentation. It's implementation details and even more - it
isn't constant and can be changed on the fly.

According to [experiments](https://github.com/afborchert/pipebuf) a
pipe buffer has the following size (in bytes) in different operation
systems:

Darwin 13.4.0	|	65536
Linux 3.16.0	|	65536
Linux 4.4.59	|	65536
Solaris 10	|	20480
Solaris 11.3	|	25599

In the same time in macOS buffer size by default is 16KB but can be
increased by operation system to 64KB.

- <https://unix.stackexchange.com/questions/11946/how-big-is-the-pipe-buffer>
- <https://github.com/afborchert/pipebuf>


### Let's look at RSpec source code

The most interesting places in the `--bisect` command implementation
are:

- `lib/rspec/core/bisect/fork_runner.rb` ([source](https://github.com/rspec/rspec-core/blob/v3.9.0/lib/rspec/core/bisect/fork_runner.rb)) и
- `lib/rspec/core/bisect/utilities.rb` ([source](https://github.com/rspec/rspec-core/blob/v3.9.0/lib/rspec/core/bisect/utilities.rb))

Here is implemented runnings specs with _fork_ (class `ForkRunner`) and
data exchange with a pipe (helper classs `Channel`).

Specs running is implemented in the followong way:

```ruby
def dispatch_run(run_descriptor)
  @run_dispatcher.dispatch_specs(run_descriptor)
  @channel.receive.tap do |result|
    if result.is_a?(String)
      raise BisectFailedError.for_failed_spec_run(result)
    end
  end
end
```

First specs are run:

```ruby
@run_dispatcher.dispatch_specs(run_descriptor)
```

and then data is read from a pipe using `@channel`. Let's look at the
method `dispatch_spec`:

```ruby
def dispatch_specs(run_descriptor)
  pid = fork { run_specs(run_descriptor) }
  Process.waitpid(pid)
end
```

Here a child process is forked and a parent process is waiting for its
termination.


### PS

The bug was fixed by removing a call `Process.waitpid(pid)`. Now a
parent process immediately reads from a pipe avoiding deadlock.

On the one hand - the issue is solve. On the other hand a new minor
issue is introduced. Noe a child process a left in a zombi state as far
as nobody gets its exit status with the system call `waitpid`, that
means a process descriptors leaking. When a number of processes in
operation system reaches a limit, not big actually (yeah, there is limit
of how many processes could exist at the same time), it will be
impossible to start a new process.


### Links

- <https://github.com/rspec/rspec-core/issues/2637>
- <https://github.com/rspec/rspec-core/pull/2669>
- <https://relishapp.com/rspec/rspec-core/docs/command-line/bisect>
- <https://linux.die.net/man/3/waitpid>
- <https://linux.die.net/man/7/pipe>
