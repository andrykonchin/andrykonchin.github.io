---
layout: post
title:  "Behind File#birthtime: How Ruby Handles Platform-Specific APIs"
date:   2026-08-14 20:57
categories: Ruby
---

Recently, while working on `File#birthtime` [support](https://github.com/truffleruby/truffleruby/pull/4324) in TruffleRuby, I investigated how CRuby handles file creation time across different operating systems. While Ruby's `File` and `File::Stat` expose standard attributes like size and timestamps through POSIX system calls like `stat(2)`, retrieving a file's creation time (its "birth time") has historically been a cross-platform challenge. This post explores how CRuby bridges POSIX limitations, modern Linux syscalls, and runtime filesystem capabilities.


## The POSIX Limitation: macOS / *BSD vs. Linux

Standard POSIX `stat(2)` defines access time (`atime`), modification time (`mtime`), and status change time (`ctime`), but completely omits file creation time. Developers often confuse `ctime` with creation time, but `ctime` actually tracks inode metadata updates, such as permission changes or file renames.

To bridge this limitation, macOS and *BSD added non-standard extensions like `st_birthtimespec` directly to their `struct stat` definition. Because BSD systems control both the kernel and C library in a unified codebase, they could utilize reserved padding fields in `struct stat` and symbol versioning to expose birth time through standard `stat(2)` calls from early on.

Linux, however, maintains a strict separation between the kernel ABI and user-space C libraries like GNU libc. The Linux 64-bit `stat(2)` system call layout had no spare fields, and writing extra timestamp data would cause stack memory corruption in existing compiled binaries. Rather than adding another one-off `stat` syscall variant, Linux kernel developers designed `statx(2)`: a modern, extensible system call capable of querying optional attributes like birth time on demand.


## Enter `statx`: The Gradual Evolution in CRuby

Introduced in Linux kernel 4.11 and glibc 2.28, `statx(2)` was adopted by CRuby in two stages.

In Ruby 2.7, direct path methods like `File.birthtime(path)` and `File#birthtime` started calling `statx(2)` on Linux. However, `File.stat(path)` continued using standard `stat(2)` under the hood, creating a subtle inconsistency across Ruby 2.7 to 3.4:

```ruby
# Ruby 2.7 - 3.4 on Linux
File.birthtime("example.txt")
# => 2026-08-14 10:00:00 +0000

File.stat("example.txt").birthtime
# => NotImplementedError: birthtime() function is unimplemented on this machine
```

In Ruby 4.0, [Feature #21205](https://bugs.ruby-lang.org/issues/21205) (committed in [18a036a6](https://github.com/ruby/ruby/commit/18a036a6133bd141dfc25cd48ced9a2b78826af6)) resolved this disparity by updating `File::Stat` on Linux to also use `statx(2)`. Because `statx(2)` accepts a request mask specifying only required attributes, `File::Stat` can query birth time on supported filesystems (such as ext4, Btrfs, or XFS) without incurring unnecessary I/O overhead.


## C Source Dive: Conditional Compilation in `file.c`

Looking into CRuby's source code ([`file.c`](https://github.com/ruby/ruby/blob/18a036a6133bd141dfc25cd48ced9a2b78826af6/file.c)), we can see how the birthtime methods are conditionally compiled depending on compile-time macros:

```c
#define HAVE_STAT_BIRTHTIME
#if defined(HAVE_STRUCT_STAT_ST_BIRTHTIMESPEC)
static VALUE
statx_birthtime(const rb_io_stat_data *st)
{
    const stat_timestamp *ts = &st->ST_(birthtimespec);
    return rb_time_nano_new(ts->tv_sec, ts->tv_nsec);
}
#elif defined(HAVE_STRUCT_STATX_STX_BTIME)
static VALUE statx_birthtime(const rb_io_stat_data *st);
#elif defined(_WIN32)
# define statx_birthtime stat_ctime
#else
# undef HAVE_STAT_BIRTHTIME
#endif
```

This preprocessor block configures `statx_birthtime` across each target platform:

- On macOS and *BSD (`HAVE_STRUCT_STAT_ST_BIRTHTIMESPEC`), it reads `st_birthtimespec` directly with nanosecond precision.
- On Linux (`HAVE_STRUCT_STATX_STX_BTIME`), it delegates to a runtime `statx(2)` helper.
- On Windows (`_WIN32`), it aliases `statx_birthtime` to `stat_ctime` (where Windows CRT `st_ctime` holds creation time).
- On unsupported platforms (`#else`), `HAVE_STAT_BIRTHTIME` is left undefined, causing `rb_stat_birthtime` to fall back to `rb_f_notimplement` (raising `NotImplementedError: unimplemented on this machine`).


## Compile-Time vs. Run-Time Limitations

Even when the Linux kernel and glibc support `statx(2)` at compile time, non-basic attributes like birth time depend on the underlying filesystem (older ext2/ext3 or certain virtual mounts do not store it).

To handle this, `statx(2)` returns a bitmask (`stx_mask`) indicating which fields the filesystem actually populated. Ruby explicitly requests `STATX_BTIME` and checks `stx_mask` in the response. If the bit is missing, Ruby raises a filesystem-specific error instead of the generic machine-wide `NotImplementedError`:

```c
# define statx_has_birthtime(st) ((st)->stx_mask & STATX_BTIME)

static void
statx_notimplement(const char *field_name)
{
    rb_raise(rb_eNotImpError,
             "%s is unimplemented on this filesystem",
             field_name);
}

static VALUE
statx_birthtime(const rb_io_stat_data *stx)
{
    if (!statx_has_birthtime(stx)) {
        /* birthtime is not supported on the filesystem */
        statx_notimplement("birthtime");
    }
    return rb_time_nano_new((time_t)stx->stx_btime.tv_sec, stx->stx_btime.tv_nsec);
}
```


## Takeaways

What appears to be a basic timestamp lookup illustrates the challenges of cross-platform runtime design. Because POSIX `stat(2)` never standardized file creation time, Ruby must juggle macOS extensions, Windows CRT peculiarities, Linux `statx(2)` system calls, and runtime filesystem bitmasks.

The real lesson is that OS-level support is only half the battle: in modern Linux environments, capability checks must happen dynamically at the filesystem level.


## Useful Links
- [Ruby Feature #21205: Make File::Stat#birthtime available on Linux](https://bugs.ruby-lang.org/issues/21205)
- [`stat(2)` Man Page](https://man7.org/linux/man-pages/man2/lstat.2.html)
- [`stat(3type)` Struct Definition](https://man7.org/linux/man-pages/man3/stat.3type.html)
- [`statx(2)` Man Page](https://man7.org/linux/man-pages/man2/statx.2.html)
