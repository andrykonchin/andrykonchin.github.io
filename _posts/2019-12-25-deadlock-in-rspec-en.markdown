---
layout:     post
title:      Deadlock in RSpec
date:       2019-12-25 00:09
categories: Ruby
---

I came across a pull request on GitHub that fixed a bug in RSpec ([_pull request_](https://github.com/rspec/rspec-core/pull/2669)). The bug caused two processes to deadlock, resulting in a RSpec hang. Since deadlocks are not a common occurrence for me, I was intrigued and decided to look into the details of the fix.

RSpec provides a convenient command-line option called `--bisect` (as documented [here](https://relishapp.com/rspec/rspec-core/docs/command-line/bisect)) that can be used to handle flaky failing specs. Sometimes, the order in which test cases are run can impact whether a spec fails or passes. To catch such issues, it's common to run the spec suite in a random order. In such cases, `--bisect` can be used to identify the minimal sequence of test cases that cause a particular spec to fail. When you use this option, RSpec reruns specs multiple times, gradually reducing their number by half, until it identifies specs that is responsible for the failure. To achieve this, RSpec runs specs in isolation, in a new system process each time.

Occasionally, when launching RSpec with the `--bisect` option, it can result in a hanging process. This issue was first reported by the maintainers of the Puppet project in [this GitHub issue](https://github.com/rspec/rspec-core/issues/2637). Additionally, they conducted an investigation and identified the root cause of the problem.

> Meanwhile the main process is hanging in waitpid at
>
> Process.waitpid(pid)
>
> A common reason why this might not show up in testing is if the result
> report in the tests is smaller than the underlying OS's buffer size. In
> that case the runner process exits after writing to the buffer and the
> parent continues happily reading from the buffer. In my case the
> testsuite results are ~93kB and the processes deadlock.

Now, let's investigate and try to understand what is happening here.


### How `--bisect` works

Let's delve into how `--bisect` actually works. RSpec leverages two methods to run specs in a separate process: using a Shell command, which utilizes system calls like `fork` and `exec`, or by _forking_ its own process. In either case, a new child process is spawned. In the first approach, the output from the specs run is written to _stdout_, which can be accessed by the parent process. In the second case, RSpec uses an unnamed [pipe](https://linux.die.net/man/7/pipe) to exchange data between the child and parent processes. The problem arises only when forking is used.

When communicating through a pipe, RSpec relies on blocking operations. This means that the child process writes data into the pipe, while the parent process waits for the child process to _exit_ before reading from the pipe. Let's examine this process more closely.

Blocking reading means waiting until a certain number of bytes are available in a pipe's buffer before reading them. For example, if a process needs to read n bytes from the pipe, but the buffer currently contains less than n bytes, the reading operation will wait until the required number of bytes are available.

Blocking writing means that if you need to write _n_ bytes, but the pipe's buffer does not have enough free space (as the buffer has a fixed and limited size), then the writing operation will wait until there is enough space in the buffer to write the _n_ bytes. This occurs after some data is read from the pipe to free enough space for the write operation.

In the case of using `fork`, the parent process uses the `waitpid` system call to wait for the child process to exit. Once the child process exits, it becomes a _zombie_ process, where system resources are freed, but the parent process is not yet aware of the child process's termination. To fully remove the child process, the parent process must retrieve the child process exit status by making `waitpid` system call.

We can visualize this process using a sequence diagram:

<img src="/assets/images/2019-12-25-deadlock-in-rspec/success.svg"/>

After creating a new child process, the _Parent process_ waits for the child process to terminate. During this time, the child process executes the specs and writes the results into the _Pipe_. Once the child process terminates, the operation system (_Kernel_) returns an exit status to the _Parent process_ as a result of the `waitpid` system call. After that, the _Parent process_ reads the output from the _Pipe_ and continues the _bisect_ operation.


### Diving into the bug

To reproduce the RSpec hanging issue, you can use the code snippet available at this [link](https://github.com/benoittgt/rspec_repro_bisect_deadlock):

```ruby
RSpec.describe "a bunch of nothing" do
  (0...3000).each do |t|
    it { expect(t).to eq t }
  end
end
```

Every time the --bisect command is run with the code snippet mentioned above, RSpec will hang out.

A rough outline of how RSpec runs specs in a child process and passes results back to a parent process is as follows:

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

To pass the results of the specs from the child process back to the parent process, RSpec creates a pipe and two `IO` objects - `@write_io` for writing and `@read_io` for reading the pipe. A new child process is then created by calling the `fork` method, which executes the passed block. Since the child process inherits all the file descriptors of the parent process, it also has access to the pipe's descriptors. The `run_specs` method is invoked in the child process, which writes 1000 bytes into the pipe. After forking the child process, the parent process waits for the child process to exit by calling the `waitpid` method, and then reads the data from the pipe.

If the code is executed, data transfer will function without any issues, and "packet size: 1000" will be displayed on the terminal.

If the number of bytes written by the child process is increased from 1000 to 66000, RSpec will hang.

The reason for this issue is pretty obvious - the buffer of the pipe has a limited size. If the child process tries to write more bytes to the pipe than the free space available in the buffer, then the writing operation will be blocked and wait until some data is read from the buffer and there is enough free space to write all the bytes. However nobody reads from the pipe. The parent process will read but only after the child process terminates. The child process cannot terminate because it cannot write the remaining bytes into the pipe. To reproduce the issue, the number of bytes to write should be greater than the buffer size of the pipe. In this case, the byte number is 66000.

The situation described above can be better understood through the following diagram:

<img src="/assets/images/2019-12-25-deadlock-in-rspec/deadlock.svg"/>

Both processes are blocked due to the use of blocking method calls - the parent process is waiting for the child process to terminate and the child process is blocked while trying to write to the pipe, resulting in a deadlock.

If the RSpec child process writes less than 64KB to a pipe, the issue does not occur. However, if it writes more than 64KB, a deadlock occurs and RSpec hangs.


### Pipe's buffer size

The buffer size of a pipe is not explicitly defined by either the POSIX standard or operating system documentation, and is subject to implementation details. Moreover, the buffer size is not constant and can potentially be modified in runtime.

Various experiments, such as those documented in [this repository](https://github.com/afborchert/pipebuf), have been conducted to determine the size of pipe buffers in different operating systems:

Darwin 13.4.0	|	65536
Linux 3.16.0	|	65536
Linux 4.4.59	|	65536
Solaris 10	|	20480
Solaris 11.3	|	25599

The buffer size in macOS is set to 16KB by default, but it can be increased by the operating system to 64KB.

- <https://unix.stackexchange.com/questions/11946/how-big-is-the-pipe-buffer>
- <https://github.com/afborchert/pipebuf>


### Let's look at RSpec source code

The most interesting places in the `--bisect` command implementation
are:

- `lib/rspec/core/bisect/fork_runner.rb` ([source](https://github.com/rspec/rspec-core/blob/v3.9.0/lib/rspec/core/bisect/fork_runner.rb)) и
- `lib/rspec/core/bisect/utilities.rb` ([source](https://github.com/rspec/rspec-core/blob/v3.9.0/lib/rspec/core/bisect/utilities.rb))

The `--bisect` command implementation has two main points of interest:
- `lib/rspec/core/bisect/fork_runner.rb` and
- `lib/rspec/core/bisect/utilities.rb`

The `fork_runner.rb` file contains the code that creates a new child process and passes results back to the parent process, while `utilities.rb` provides some useful functions that are used throughout the bisecting process.

Here is how running specs with _fork_ (using class `ForkRunner`) and
data exchange with a pipe (using the helper class `Channel`) is implemented:

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

The first step - to run specs:

```ruby
@run_dispatcher.dispatch_specs(run_descriptor)
```

The method `dispatch_spec` reads data from the pipe using `@channel`:

```ruby
def dispatch_specs(run_descriptor)
  pid = fork { run_specs(run_descriptor) }
  Process.waitpid(pid)
end
```

Here the `fork` method is used to create a child process, while the parent process waits for the child process to exit before proceeding.


### PS

The bug was resolved by removing the `Process.waitpid(pid)` call, which allowed the parent process to immediately read from the pipe, thus avoiding any deadlocks.

Although the original deadlock issue was resolved by removing the Process.waitpid(pid) call and immediately reading from the pipe, a new minor issue was introduced. Now the child process is left in a zombie state as no one gets its exit status with the waitpid system call, resulting in process descriptor leaks. If the number of processes in the operating system reaches its limit (which is not very high), it becomes impossible to start a new process.


### Links

- <https://github.com/rspec/rspec-core/issues/2637>
- <https://github.com/rspec/rspec-core/pull/2669>
- <https://relishapp.com/rspec/rspec-core/docs/command-line/bisect>
- <https://linux.die.net/man/3/waitpid>
- <https://linux.die.net/man/7/pipe>
