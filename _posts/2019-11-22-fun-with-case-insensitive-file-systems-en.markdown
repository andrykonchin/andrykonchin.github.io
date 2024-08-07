---
layout:     post
title:      "Unexpected issue with case-insensitive file systems"
date:       2019-11-22 23:37
categories: Ruby
---

Not so long ago I've encountered an interesting issue and learned yet
another lessen. The issue was related to macOS file system, that is by
default case-insensitive (as well as in Windows). And combination of
macOS and Git caused unforeseeable problems in a commercial project I
have been working on.


### Case-insensitive file systems in practice

A file name may contain characters both uppercased and downcased. But
inside a case-insensitive file system a character case is ignored in a
file or directory name, that's we can reference a file `about.md` in a
shell command as `About.md`, or `ABout.md` or even `ABOut.md`.

Let's illustrate this with an example. Imagin we have a file `about.md`
on macOS:

```shell
$ ls -la
total 8
drwxr-xr-x  3 andrykonchin  staff   96 Nov  4 22:01 .
drwxr-xr-x  7 andrykonchin  staff  224 Nov  4 21:59 ..
-rw-r--r--  1 andrykonchin  staff  442 Nov  4 23:36 about.md
```

And here we reference it successfully with shell command `ls` in
different ways:

```
$ ls -la about.md
-rw-r--r--  1 andrykonchin  staff  442 Nov  4 23:36 about.md

$ ls -la About.md
-rw-r--r--  1 andrykonchin  staff  442 Nov  4 23:36 About.md

$ ls -la ABout.md
-rw-r--r--  1 andrykonchin  staff  442 Nov  4 23:36 ABout.md

$ ls -la ABOut.md
-rw-r--r--  1 andrykonchin  staff  442 Nov  4 23:36 ABOut.md
```

If in macOS we copied a directory from some external case-sensitive file
system (e.g. a flash-drive with FAT32 file system, or a shared directory
on some other computer), we might encountered unexpected surprises.

If there are two files in such a directory with similar names and
difference is only in characters case, then in macOS only one of these
files will be visible and can be reached. If there are two such similar
directories - then they will be just merged into a single one.


### Git and case-insensitivity

In order to support case-insensitive file systems in Git there is a
config option `core.ignoreCase`. If it is enabled then Git ignores
character case in filenames and pathes.

For instance, if there is a file `Gemfile` and you rename it to
`gemfile`, then Git will not treat it as a change that could be
committed:

```shell
$ mv Gemfile gemfile

$ git status
On branch master

No commits yet

nothing to commit (create/copy files and use "git add" to track)
```

If you modify this renamed to `gemfile` file and check Git status, then
the old name `Gemfile` will be used in the output, that is taken
from the Git repository metadata:

```shell
$ echo foo > gemfile

$ git status
On branch master
Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
    modified:   Gemfile   # <====== !!!!

no changes added to commit (use "git add" and/or "git commit -a")
```


### So what is a problem?

One of the ways to shoot yourself in the foot is to create and commit in
Git on Linux (where usually file systems are case-sensitive) two files
in the same directory that have the same names but some characters are
in different case. On macOS only one of them will be visible.

There is a more sophisticated way. You can modify a file on macOS, then
rename it by changing only character case and then commit it in Git. If
the `core.ignoreCase` Git option is disabled then locally you will see
only a file with the new name but Git will have commited both file
versions - with old and new name. If somebody on Linux pulls the
committed changes then he will have in the working directory both files.
If somebody on macOS pulls the changes - he will see only one of them.
What file name overrides the other depends only on Git as far as it is
Git that manages the working directory and copies files from the
metadata in the `.git` directory.


### Possible solutions

The following measures may be helpful:
* all the developers in a project use _case-sensitive_ file systems (TBD
  что сразу исключает Windows) or
* developers that use case-insensitive file systems should ensure that
  or Git option `core.ignoreCase` is enabled
* just check that there are no file duplicates in a Git repository on a
  CI server

Regarding the last option - on *-nix systems it could be done easily
with online shell command similar to:

```shell
git ls-tree -r -t --name-only HEAD . | sort -f | uniq -i -d
```

The output contans a list of files duplicates.

If there is a case-sensitive file system on CI, then instead of the
`git` command a plain `find` could be used:

```shell
find . -type f | sort -f | uniq -i -d
```

Interestingly, but on Windows it's also possible to enable
case-sensitive behavior. Starting from Windows 10 there is a Windows
subsystem WSL (Subsystem for Linux). So it's now possible to make a
particular directory case-sensitive using a standard `fsutil` utility.


### How we shoot ourselfs in the foot

We faiced this issue in a commersial projects unexpectedly. One of the
unit tests gets fail on CI. Locally it passes successfully, but on CI
constantly fails.

When we started investigation we found out that there are duplicated VCR
cassettes committed in the project's Git repository (they are used in
unit test to record and replay HTTP responsed and requests to
third-party services) used for this test. One of cassetts contained
outdated data so the test passes using the fresh cassett and fails with
the outdated one. The cassetts are generated automatically and path and
filenames are based on a test's title and surrounding RSpec `context`
and `describe` sections. Someone renamed the test title but changed only
characters case so a new VCR cassett was created with a new name.

For instance if we have the following RSpec test case:

```ruby
describe "Domestic services" do
  it "returns a rate and services"
end
```

and to rename an outer `describe`'s title in the following way:

```ruby
describe "domestic services" do
  it "returns a rate and services"
end
```

then a VCR cassett will be recreated with new path and we will have two
different files:
- `vcr_rspec/.../Domestic_services/returns_a_rate_and_services.yml`
- `vcr_rspec/.../domestic_services/returns_a_rate_and_services.yml`

We mostly used macOS in the team so the fresh cassett was picked locally
and the test passed successfully. But we used Ubuntu on CI and an the
outdated cassett was constantly used there what leaded to the test
failure.

We fixed the test by removing a duplicate in teh Git repository and by
renaming the fresh cassett. But the issue wasn't solved. Soon we had 20
such file duplicates.


### Conclusion

Let me tell obvious statement (TBD):
* you will avoid numerous problems if you use the same environment for
  all the purposes - development, production, testing etc
* if there are differences - you need to know them and what issues them
  could cause.


### Useful links

- <https://git-scm.com/docs/git-ls-tree>
- <https://habr.com/ru/company/kaspersky/blog/414239/>
- <https://coderwall.com/p/mgi8ja/case-sensitive-git-in-mac-os-x-like-a-pro>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
