---
layout: post
title:  "Behind File#birthtime: How Ruby Handles Platform-Specific APIs"
date:   2026-08-14 20:57
categories: Ruby
---

Recently, I worked on implementing `File#birthtime` support in TruffleRuby ([PR #4324](https://github.com/truffleruby/truffleruby/pull/4324)). To ensure compatibility with MRI (CRuby) across different operating systems, I had to dig into CRuby's source code and the underlying OS system calls. It turned out to be a fascinating dive into POSIX limitations, modern Linux syscalls, and runtime platform detection.

Retrieving file metadata in Ruby is usually straightforward. The `File` class provides numerous convenient methods like `executable?`, `size`, and others. These attributes are also exposed through the `File::Stat` class ([documentation](https://rubyapi.org/4.0/o/file/stat)), which is returned by `File#stat`.

Under the hood, these methods map to POSIX system calls such as `stat(2)`, `fstat(2)`, and `lstat(2)`, which return a `stat(3type)` structure containing information about the file.

However, getting the **file creation time** (or "birth time") has historically been a platform-dependent headache.


### The POSIX Limitation: macOS / \*BSD vs. Linux

The reason `birthtime` is so intriguing is that standard POSIX `stat(2)` system calls **do not support file creation time**. The standard structure returns access time (`atime`), modification time (`mtime`), and change time (`ctime`), but completely omits creation time.

To work around this:
* **macOS and \*BSD** extended the POSIX standard by adding extra fields (like `st_birthtime`) directly to their implementation of the `stat` structure. Thus, Ruby has long supported `File#birthtime` on macOS and \*BSD systems.
* **Linux**, on the other hand, stuck strictly to the POSIX structure for `stat(2)`. As a result, prior to Ruby 4.0, calling `File#birthtime` on Linux would raise a `NotImplementedError`:

```ruby
File.birthtime("example.txt")
# => NotImplementedError: birthtime is not supported on this platform
```


### Enter `statx` in Ruby 4.0

To resolve this on Linux, Ruby 4.0 introduced support for `File#birthtime` via a relatively new Linux-specific system call: `statx(2)` (implemented in [Feature #21205](https://bugs.ruby-lang.org/issues/21205) / [commit 18a036a6](https://github.com/ruby/ruby/commit/18a036a6133bd141dfc25cd48ced9a2b78826af6)).

Unlike `stat`, `statx` is a modern, non-POSIX system call introduced in Linux kernel 4.11 (and glibc 2.28) that supports retrieving extended file attributes, including the file birth time (`STATX_BTIME`).

`statx(2)` is also designed with performance in mind: retrieving certain file attributes can require additional time and disk I/O, so `statx` allows the caller to pass a `mask` parameter specifying only the fields that are actually needed. This ensures the caller doesn't have to pay for attributes they don't care about.

With Ruby 4.0, if your Linux kernel, glibc, and the underlying filesystem (such as ext4, Btrfs, or XFS) support `statx`, `File#birthtime` will now work seamlessly.


### C Source Dive: Conditional Compilation in `file.c`

Looking into CRuby's source code ([`file.c`](https://github.com/ruby/ruby/blob/v4.0.6/file.c)), we can see how the birthtime methods are conditionally compiled depending on compile-time macros.

Ruby first defines `HAVE_STAT_BIRTHTIME` if any of the target platform APIs are available:

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

If the compilation target platform doesn't support any birthtime mechanism, `HAVE_STAT_BIRTHTIME` is undefined. The corresponding methods (such as `rb_stat_birthtime`) are then mapped to `rb_f_notimplement`, which raises the standard compile-time `NotImplementedError` when called from Ruby:

```c
#if defined(HAVE_STAT_BIRTHTIME)
static VALUE
rb_stat_birthtime(VALUE self)
{
    return statx_birthtime(get_stat(self));
}
#else
# define rb_stat_birthtime rb_f_notimplement
#endif
```


### Compile-Time vs. Run-Time Limitations

One of the most interesting aspects of the Linux `statx(2)` implementation is that even if the kernel and glibc support `statx` at compile time, non-basic attributes like birthtime may not be supported by every filesystem (such as older ext2/ext3 or certain file system drivers).

Because support for non-basic attributes varies across filesystems on Linux, callers cannot assume that requested fields are always available. Instead, the `statx(2)` system call returns a bitmask (`stx_mask`) indicating which file attributes were actually supported and populated by the filesystem. The caller side must always check this mask before using the data.

Ruby explicitly passes `STATX_BTIME` in the request mask and inspects `stx_mask` in the response. If the `STATX_BTIME` bit is not set, Ruby raises a custom filesystem-specific error instead of the generic machine-wide `NotImplementedError`:

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


### Summary of System Calls

| Operating System | Mechanism Used | Support Status |
| --- | --- | --- |
| **macOS / \*BSD** | Extended `stat(2)` (`st_birthtime`) | Supported |
| **Linux (Ruby < 4.0)** | Standard `stat(2)` | Not Supported (`NotImplementedError: function is unimplemented on this machine`) |
| **Linux (Ruby >= 4.0)** | `statx(2)` (`STATX_BTIME`) | Supported (Raises `NotImplementedError: birthtime is unimplemented on this filesystem` if filesystem doesn't support it) |
| **Windows** | WinAPI (`GetFileTime`) | Supported |


### PS

Cross-platform support is hard. Even for something as basic as "when was this file created?", you have to deal with POSIX quirks, kernel differences, and various filesystems. It's neat to see how much low-level chaos Ruby implementations quietly handle so developers don't have to.


### Useful Links
* [TruffleRuby PR #4324](https://github.com/truffleruby/truffleruby/pull/4324)
* [`stat(2)` Man Page](https://man7.org/linux/man-pages/man2/lstat.2.html)
* [`stat(3type)` Struct Definition](https://man7.org/linux/man-pages/man3/stat.3type.html)
* [`statx(2)` Man Page](https://man7.org/linux/man-pages/man2/statx.2.html)
