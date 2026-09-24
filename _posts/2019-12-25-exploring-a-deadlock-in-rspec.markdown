---
layout:     post
title:      Exploring a Deadlock in RSpec
date:       2019-12-25 00:09
categories: Ruby
---

While deadlocks are a classic topic in multi-threaded systems programming, they rarely make an appearance in everyday Ruby development. That made a recent bug fix in RSpec stand out: a [pull request](https://github.com/rspec/rspec-core/pull/2669) (released in RSpec 3.9.1) resolved an issue where two processes deadlocked, causing the test suite to hang indefinitely. Intrigued by the bug, I decided to investigate how such a deadlock could happen in standard Ruby tooling and how it was fixed.

RSpec provides the [`--bisect`](https://rspec.info/features/3-13/rspec-core/command-line/bisect/) command-line option to help track down order-dependent test failures. When test failures depend on the order in which examples run, `--bisect` repeatedly runs subsets of the suite, halving the number of candidate specs on each run until it isolates the minimal sequence causing the failure. To ensure clean isolation between runs, RSpec executes each candidate run in a separate process.

Under certain conditions, running RSpec with `--bisect` hangs completely. The issue was originally [reported](https://github.com/rspec/rspec-core/issues/2637) by maintainers of the Puppet project, who identified that the parent process was stuck in a blocking `Process.waitpid(pid)` call:

> Meanwhile the main process is hanging in waitpid at
>
> Process.waitpid(pid)
>
> A common reason why this might not show up in testing is if the result
> report in the tests is smaller than the underlying OS's buffer size. In
> that case the runner process exits after writing to the buffer and the
> parent continues happily reading from the buffer. In my case the
> testsuite results are ~93kB and the processes deadlock.

Let's investigate how this deadlock occurs.


## How `--bisect` Works Under the Hood

RSpec supports two ways to run isolated specs in child processes: via a shell command (which invokes `fork` and `exec`), or by directly forking the Ruby process. In the shell-command approach, the child process writes test output to *stdout*, which the parent reads. In the fork approach, RSpec allocates an unnamed [pipe](https://linux.die.net/man/7/pipe) for inter-process communication (IPC). The problem arises only when forking is used.

When communicating through a pipe, RSpec relies on blocking operations: the child process writes test results into the pipe, while the parent process waits for the child to terminate via `waitpid` before reading from the pipe.

<img src="/assets/images/2019-12-25-exploring-a-deadlock-in-rspec/success.svg"/>

Once the child process terminates, `waitpid` reaps its exit status and unblocks the parent, which reads the test output and continues the bisect algorithm.


## Reproducing the Deadlock

The hang can be reproduced with a [synthetic test suite](https://github.com/benoittgt/rspec_repro_bisect_deadlock) created by Benoît Tigeot:

```ruby
RSpec.describe "a bunch of nothing" do
  (0...3000).each do |t|
    it { expect(t).to eq t }
  end
end
```

Running `rspec --bisect=verbose` against these 3,000 examples hangs every time.

We can isolate this IPC mechanism in a minimal Ruby script:

```ruby
@read_io, @write_io = IO.pipe

def run_specs
  packet = '*' * 1000
  @write_io.write("#{packet.bytesize}\n#{packet}")
end

pid = fork { run_specs }
Process.waitpid(pid)

packet_size = Integer(@read_io.gets)
packet = @read_io.read(packet_size)
```

With a 1,000-byte payload, the script finishes immediately. But increase the payload to 66,000 bytes, and it hangs.

The culprit is the operating system's pipe buffer capacity. When the payload fits in the buffer, the write finishes and the child exits cleanly. But once the payload exceeds the buffer, the child's `write` blocks until data is read. Since the parent won't read from the pipe until `waitpid` returns, and the child can't terminate until `write` finishes, both processes deadlock:

<img src="/assets/images/2019-12-25-exploring-a-deadlock-in-rspec/deadlock.svg"/>

Pipe buffer capacities are not strictly mandated by POSIX and [vary across platforms](https://github.com/afborchert/pipebuf), though modern Linux and macOS kernels typically allocate 64 KB (macOS allocates 16 KB initially and expands it up to 64 KB). Any test payload exceeding this threshold reliably triggers the deadlock.


## Inspecting RSpec's Implementation

In `rspec-core`, the relevant fork runner logic is contained in two classes:
- [`ForkRunner`](https://github.com/rspec/rspec-core/blob/v3.9.0/lib/rspec/core/bisect/fork_runner.rb) handles spawning processes.
- [`Channel`](https://github.com/rspec/rspec-core/blob/v3.9.0/lib/rspec/core/bisect/utilities.rb) manages serialization over the pipe.

In `ForkRunner#dispatch_run`, RSpec first runs the candidate specs and only then reads the result from the pipe:

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

Looking inside `dispatch_specs`:

```ruby
def dispatch_specs(run_descriptor)
  pid = fork { run_specs(run_descriptor) }
  Process.waitpid(pid)
end
```

It forks a child process and immediately waits for it to terminate. Because the parent is blocked waiting for child termination before it ever attempts to read from the pipe, any output exceeding the pipe buffer capacity leads to an inescapable deadlock.


## The Flaw in the Initial Fix: Zombie Processes

To resolve the deadlock, pull request [#2669](https://github.com/rspec/rspec-core/pull/2669) simply removed the `waitpid` call. This allowed the parent to read from the pipe while the child writes, preventing the pipe buffer from filling up.

However, omitting `waitpid` left terminated child processes unreaped in a zombie state. In test suites requiring hundreds of bisection runs, these accumulating zombies quickly exhaust the operating system's process table limit, preventing any new processes from being spawned.


## The Resolution: Process.detach

When this article was first published in December 2019, the original conclusion noted that removing `waitpid` introduced this new issue. In June 2020, Benoît Tigeot confirmed the leak and opened pull request [#2739](https://github.com/rspec/rspec-core/pull/2739), introducing [`Process.detach(pid)`](https://ruby-doc.org/core/Process.html#method-c-detach):

```ruby
def dispatch_specs(run_descriptor)
  pid = fork { run_specs(run_descriptor) }
  Process.detach(pid)
end
```

`Process.detach(pid)` spawns a background Ruby thread to wait on the child and reap its exit status. This allows the parent to immediately read from the pipe without blocking, avoiding the deadlock while preventing zombie leaks.


## Conclusion

This deadlock stems from treating a bounded streaming pipe like a static file: waiting for a child to terminate before reading its output. In Unix IPC, reading must happen concurrently with writing - either by draining the pipe to EOF before calling `waitpid`, or by decoupling process reaping with tools like `Process.detach`.
