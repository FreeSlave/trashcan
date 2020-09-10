# Trash can

[![Build Status](https://travis-ci.org/FreeSlave/trashcan.svg?branch=master)](https://travis-ci.org/FreeSlave/trashcan) [![Windows Build Status](https://ci.appveyor.com/api/projects/status/github/FreeSlave/trashcan?branch=master&svg=true)](https://ci.appveyor.com/project/FreeSlave/trashcan)

Trash can operations implemented in D programming language.
The **moveToTrash** function places a passed file or directory to trash can. The **Trashcan** class allows to list trashcan contents, restore or delete items.

[Online documentation](https://freeslave.github.io/trashcan/trashcan.html)

## Platform support and implementation details

On Freedesktop environments (e.g. GNU/Linux) the library follows [Trash Can Specification](https://www.freedesktop.org/wiki/Specifications/trash-spec/).

On Windows [SHFileOperation](https://docs.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shfileoperationw) is used to move files to trash, and [IShellFolder2](https://docs.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-ishellfolder2) is used as an interface to recycle bin to list, delete and undelete items.

On OSX FSMoveObjectToTrashSync is used to move files to trash. Listing, deleting and undeleting items in the trash can are not currently supported on macOS.

Other platforms are not supported.

## Currently missing features

* Notifying changes in trash can contents (or at least providing the data required to implement this feature for the library user).

## Examples

### [Put to trash can](examples/put.d)

Run to put file or directory to trash can:

    dub examples/put.d path/to/file

### [Manage items in trash can](examples/manage.d)

Interactively delete items from trashcan or restore them to their original location.

    dub examples/manage.d
