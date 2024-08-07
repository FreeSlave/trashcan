/**
 * Moving files and directories to trash can.
 * Copyright:
 *  Roman Chistokhodov, 2016
 * License:
 *  $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 */

module trashcan;

import std.path;
import std.string;
import std.file;
import std.exception;
import std.range : InputRange, inputRangeObject;
import std.datetime;

import isfreedesktop;

static if (isFreedesktop) {
    import std.uri : encode, decode;
    import volumeinfo;
    import xdgpaths : xdgDataHome, xdgAllDataDirs;
}

/**
 * Flags to rule the trashing behavior.
 *
 * $(BLUE Valid only for freedesktop environments).
 *
 * See_Also: $(LINK2 https://specifications.freedesktop.org/trash-spec/trashspec-1.0.html, Trash specification).
 */
enum TrashOptions : int
{
    /**
     * No options. Just move file to user home trash directory
     * not paying attention to partition where file resides.
     */
    none = 0,
    /**
     * If file that needs to be deleted resides on non-home partition
     * and top trash directory ($topdir/.Trash/$uid) failed some check,
     * fallback to user top trash directory ($topdir/.Trash-$uid).
     *
     * Makes sense only in conjunction with $(D useTopDirs).
     */
    fallbackToUserDir = 1,
    /**
     * If file that needs to be deleted resides on non-home partition
     * and checks for top trash directories failed,
     * fallback to home trash directory.
     *
     * Makes sense only in conjunction with $(D useTopDirs).
     */
    fallbackToHomeDir = 2,

    /**
     * Whether to use top trash directories at all.
     *
     * If no $(D fallbackToUserDir) nor $(D fallbackToHomeDir) flags are set,
     * and file that needs to be deleted resides on non-home partition,
     * and top trash directory ($topdir/.Trash/$uid) failed some check,
     * exception will be thrown. This can be used to report errors to administrator or user.
     */
    useTopDirs = 4,

    /**
     * Whether to check presence of 'sticky bit' on $topdir/.Trash directory.
     *
     * Makes sense only in conjunction with $(D useTopDirs).
     */
    checkStickyBit = 8,

    /**
     * All flags set.
     */
    all = (TrashOptions.fallbackToUserDir | TrashOptions.fallbackToHomeDir | TrashOptions.checkStickyBit | TrashOptions.useTopDirs)
}

static if (isFreedesktop)
{
private:
    import std.format : format;

    @trusted string numberedBaseName(scope string path, uint number) {
        return format("%s %s%s", path.baseName.stripExtension, number, path.extension);
    }

    unittest
    {
        assert(numberedBaseName("/root/file.ext", 1) == "file 1.ext");
        assert(numberedBaseName("/root/file", 2) == "file 2");
    }

    @trusted string ensureDirExists(scope string dir) {
        std.file.mkdirRecurse(dir);
        return dir;
    }

    import core.sys.posix.sys.types;
    import core.sys.posix.sys.stat;
    import core.sys.posix.unistd;
    import core.sys.posix.fcntl;

    @trusted string topDir(string path)
    in {
        assert(path.isAbsolute);
    }
    do {
        return volumePath(path);
    }

    void checkDiskTrashMode(mode_t mode, const bool checkStickyBit = true)
    {
        enforce(!S_ISLNK(mode), "Top trash directory is a symbolic link");
        enforce(S_ISDIR(mode), "Top trash path is not a directory");
        if (checkStickyBit) {
            enforce((mode & S_ISVTX) != 0, "Top trash directory does not have sticky bit");
        }
    }

    unittest
    {
        assertThrown(checkDiskTrashMode(S_IFLNK|S_ISVTX));
        assertThrown(checkDiskTrashMode(S_IFDIR));
        assertNotThrown(checkDiskTrashMode(S_IFDIR|S_ISVTX));
        assertNotThrown(checkDiskTrashMode(S_IFDIR, false));
    }

    @trusted string checkDiskTrash(scope string topdir, const bool checkStickyBit = true)
    in {
        assert(topdir.length);
    }
    do {
        string trashDir = buildPath(topdir, ".Trash");
        stat_t trashStat;
        enforce(lstat(trashDir.toStringz, &trashStat) == 0, "Top trash directory does not exist");
        checkDiskTrashMode(trashStat.st_mode, checkStickyBit);
        return trashDir;
    }

    @safe string userTrashSubdir(scope string trashDir, uid_t uid) {
        import std.conv : to;
        return buildPath(trashDir, uid.to!string);
    }

    unittest
    {
        assert(userTrashSubdir("/.Trash", 600) == buildPath("/.Trash", "600"));
    }

    @trusted string ensureUserTrashSubdir(scope string trashDir)
    {
        return userTrashSubdir(trashDir, getuid()).ensureDirExists();
    }

    @safe string userTrashDir(string topdir, uid_t uid) {
        return buildPath(topdir, format(".Trash-%s", uid));
    }

    unittest
    {
        assert(userTrashDir("/topdir", 700) == buildPath("/topdir", ".Trash-700"));
    }

    @trusted string ensureUserTrashDir(scope string topdir)
    {
        return userTrashDir(topdir, getuid()).ensureDirExists();
    }
}

version(OSX)
{
private:
    import core.sys.posix.dlfcn;

    struct FSRef {
        char[80] hidden;
    };

    alias ubyte Boolean;
    alias int OSStatus;
    alias uint OptionBits;

    version (TrashCanStatic) {
        extern(C) @nogc @system OSStatus FSPathMakeRefWithOptions(const(char)* path, OptionBits, FSRef*, Boolean*) nothrow;
        extern(C) @nogc @system OSStatus FSMoveObjectToTrashSync(const(FSRef)*, FSRef*, OptionBits) nothrow;
    } else {
        extern(C) @nogc @system OSStatus _dummy_FSPathMakeRefWithOptions(const(char)* path, OptionBits, FSRef*, Boolean*) nothrow {return 0;}
        extern(C) @nogc @system OSStatus _dummy_FSMoveObjectToTrashSync(const(FSRef)*, FSRef*, OptionBits) nothrow {return 0;}
    }
}

/**
 * Move file or directory to trash can.
 * Params:
 *  path = Path of item to remove. Must be absolute.
 *  options = Control behavior of trashing on freedesktop environments.
 * Throws:
 *  $(B Exception) when given path is not absolute or does not exist, or some error occured during operation,
 *  or the operation is not supported on the current platform.
 */
@trusted void moveToTrash(scope string path, TrashOptions options = TrashOptions.all)
{
    if (!path.isAbsolute) {
        throw new Exception("Path must be absolute");
    }
    if (!path.exists) {
        throw new Exception("Path does not exist");
    }

    version(Windows) {
        import core.sys.windows.shellapi;
        import core.sys.windows.winbase;
        import core.stdc.wchar_;
        import std.windows.syserror;
        import std.utf;

        SHFILEOPSTRUCTW fileOp;
        fileOp.wFunc = FO_DELETE;
        fileOp.fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR | FOF_ALLOWUNDO;
        auto wFileName = (path ~ "\0\0").toUTF16();
        fileOp.pFrom = wFileName.ptr;
        int r = SHFileOperation(&fileOp);
        if (r != 0) {
            import std.format;
            throw new Exception(format("SHFileOperation failed with error code %d", r));
        }
    } else version(OSX) {
        version (TrashCanStatic) {}
        else {
            void* handle = dlopen("CoreServices.framework/Versions/A/CoreServices", RTLD_NOW | RTLD_LOCAL);
            if (handle is null)
                throw new Exception(fromStringz(dlerror()).idup);
            scope(exit) dlclose(handle);

            auto FSPathMakeRefWithOptions = cast(typeof(&_dummy_FSPathMakeRefWithOptions))dlsym(handle, "FSPathMakeRefWithOptions");
            if (FSPathMakeRefWithOptions is null) {
                throw new Exception(fromStringz(dlerror()).idup);
            }

            auto FSMoveObjectToTrashSync = cast(typeof(&_dummy_FSMoveObjectToTrashSync))dlsym(handle, "FSMoveObjectToTrashSync");
            if (FSMoveObjectToTrashSync is null) {
                throw new Exception(fromStringz(dlerror()).idup);
            }
        }

        FSRef source;
        enforce(FSPathMakeRefWithOptions(toStringz(path), 1, &source, null) == 0, "Could not make FSRef from path");
        FSRef target;
        enforce(FSMoveObjectToTrashSync(&source, &target, 0) == 0, "Could not move path to trash");
    } else {
        static if (isFreedesktop) {
            string dataPath = xdgDataHome(null, true);
            if (!dataPath.length) {
                throw new Exception("Could not access data folder");
            }
            dataPath = dataPath.absolutePath;

            string trashBasePath;
            bool usingTopdir = false;
            string fileTopDir;

            if ((options & TrashOptions.useTopDirs) != 0) {
                string dataTopDir = topDir(dataPath);
                fileTopDir = topDir(path);

                enforce(fileTopDir.length, "Could not get topdir of file being trashed");
                enforce(dataTopDir.length, "Could not get topdir of home data directory");

                if (dataTopDir != fileTopDir) {
                    try {
                        string diskTrash = checkDiskTrash(fileTopDir, (options & TrashOptions.checkStickyBit) != 0);
                        trashBasePath = ensureUserTrashSubdir(diskTrash);
                        usingTopdir = true;
                    } catch(Exception e) {
                        try {
                            if ((options & TrashOptions.fallbackToUserDir) != 0) {
                                trashBasePath = ensureUserTrashDir(fileTopDir);
                                usingTopdir = true;
                            } else {
                                throw e;
                            }
                        } catch(Exception e) {
                            if (!(options & TrashOptions.fallbackToHomeDir)) {
                                throw e;
                            }
                        }
                    }
                }
            }

            if (trashBasePath is null) {
                trashBasePath = ensureDirExists(buildPath(dataPath, "Trash"));
            }
            enforce(trashBasePath.length, "Could not access base trash folder");

            string trashInfoDir = ensureDirExists(buildPath(trashBasePath, "info"));
            string trashFilePathsDir = ensureDirExists(buildPath(trashBasePath, "files"));

            string trashInfoPath = buildPath(trashInfoDir, path.baseName ~ ".trashinfo");
            string trashFilePath = buildPath(trashFilePathsDir, path.baseName);

            import std.conv : octal;
            import core.stdc.errno;

            auto currentTime = Clock.currTime;
            currentTime.fracSecs = Duration.zero;
            string timeString = currentTime.toISOExtString();
            string contents = format("[Trash Info]\nPath=%s\nDeletionDate=%s\n", (usingTopdir ? path.relativePath(fileTopDir) : path).encode(), timeString);

            const mode = O_CREAT | O_WRONLY | O_EXCL;
            int fd;
            uint number = 1;
            while(trashFilePath.exists || ((fd = .open(toStringz(trashInfoPath), mode, octal!666)) == -1 && errno == EEXIST)) {
                string baseName = numberedBaseName(path, number);
                trashFilePath = buildPath(trashFilePathsDir, baseName);
                trashInfoPath = buildPath(trashInfoDir, baseName ~ ".trashinfo");
                number++;
            }
            errnoEnforce(fd != -1);
            scope(exit) .close(fd);
            errnoEnforce(write(fd, contents.ptr, contents.length) == contents.length);

            path.rename(trashFilePath);
        } else {
            throw new Exception("Trashing operation is not implemented on this platform");
        }
    }
}

unittest
{
    assertThrown(moveToTrash("notabsolute"));
}

version(Windows)
{
    import std.typecons : RefCounted, refCounted, RefCountedAutoInitialize;
    import std.windows.syserror : WindowsException;

    import core.sys.windows.windows;
    import core.sys.windows.shlobj;
    import core.sys.windows.shlwapi;
    import core.sys.windows.wtypes;
    import core.sys.windows.oaidl;
    import core.sys.windows.objidl;

    pragma(lib, "Ole32");
    pragma(lib, "OleAut32");
}

version(Windows) private struct ItemIdList
{
    @disable this(this);
    this(LPITEMIDLIST pidl) {
        this.pidl = pidl;
    }
    alias pidl this;
    LPITEMIDLIST pidl;
    ~this() {
        if (pidl) {
            CoTaskMemFree(pidl);
            pidl = null;
        }
    }
}

/// Item (file or folder) stored in the trashcan.
struct TrashcanItem
{
    version(Windows) private @trusted this(string restorePath, bool isDir, ref scope const SysTime deletionTime, LPITEMIDLIST pidl) {
        _restorePath = restorePath;
        _isDir = isDir;
        _deletionTime = deletionTime;
        this.pidl = refCounted(ItemIdList(pidl));
    }
    static if (isFreedesktop) {
        private @trusted this(string restorePath, bool isDir, ref scope const SysTime deletionTime, string trashInfoPath, string trashedPath) {
            assert(trashInfoPath.length != 0);
            assert(trashedPath.length != 0);
            _restorePath = restorePath;
            _isDir = isDir;
            _deletionTime = deletionTime;
            _trashInfoPath = trashInfoPath;
            _trashedPath = trashedPath;
        }
    }
    /// Original location of the item (absolute path) before it was moved to trashcan.
    @safe @property @nogc nothrow pure string restorePath() const {
        return _restorePath;
    }
    /// Whether the item is directory.
    @safe @property @nogc nothrow pure  bool isDir() const {
        return _isDir;
    }
    /// The time when the item was moved to trashcan.
    @safe @property @nogc nothrow pure SysTime deletionTime() const {
        return _deletionTime;
    }
    version(D_Ddoc) {
        static if (!is(typeof(LPITEMIDLIST.init)))
        {
            static struct LPITEMIDLIST {}
        }
        /**
         * Windows-specific function to get LPITEMIDLIST associated with item.
         *
         * Note:
         *  The returned object must not outlive this TrashcanItem (or its copies). If you want to keep this object around use $(LINK2 https://msdn.microsoft.com/en-us/library/windows/desktop/bb776433(v=vs.85).aspx, ILClone). Don't forget to call ILFree or CoTaskMemFree, when it's no longer needed.
         */
        @system @property @nogc nothrow LPITEMIDLIST itemIdList() {return LPITEMIDLIST.init;}
        /**
         * Freedesktop-specific function to get .trashinfo file path.
         */
        @property @nogc nothrow string trashInfoPath() const {return string.init;}
        /**
         * Freedesktop-specific function to get the path where the trashed file or directory is located.
         */
        @property @nogc nothrow string trashedPath() const {return string.init;}
    } else version(Windows) {
        @system @property @nogc nothrow LPITEMIDLIST itemIdList() {
            if (pidl.refCountedStore.isInitialized)
                return pidl.refCountedPayload.pidl;
            return null;
        }
    } else static if (isFreedesktop) {
        @safe @property @nogc nothrow string trashInfoPath() const {
            return _trashInfoPath;
        }
        @safe @property @nogc nothrow string trashedPath() const {
            return _trashedPath;
        }
    }
private:
    string _restorePath;
    bool _isDir;
    SysTime _deletionTime;
    version(Windows) RefCounted!(ItemIdList, RefCountedAutoInitialize.no) pidl;
    static if (isFreedesktop) {
        string _trashInfoPath;
        string _trashedPath;
    }
}

version(Windows) private
{
    // Redefine IShellFolder2 since it's bugged in druntime
    interface IShellFolder2 : IShellFolder
    {
        HRESULT GetDefaultSearchGUID(GUID*);
        HRESULT EnumSearches(IEnumExtraSearch*);
        HRESULT GetDefaultColumn(DWORD, ULONG*, ULONG*);
        HRESULT GetDefaultColumnState(UINT, SHCOLSTATEF*);
        HRESULT GetDetailsEx(LPCITEMIDLIST, const(SHCOLUMNID)*, VARIANT*);
        HRESULT GetDetailsOf(LPCITEMIDLIST, UINT, SHELLDETAILS*);
        HRESULT MapColumnToSCID(UINT, SHCOLUMNID*);
    }

    // Define missing declarations
    alias SICHINTF = DWORD;

    enum SIGDN {
      SIGDN_NORMALDISPLAY,
      SIGDN_PARENTRELATIVEPARSING,
      SIGDN_DESKTOPABSOLUTEPARSING,
      SIGDN_PARENTRELATIVEEDITING,
      SIGDN_DESKTOPABSOLUTEEDITING,
      SIGDN_FILESYSPATH,
      SIGDN_URL,
      SIGDN_PARENTRELATIVEFORADDRESSBAR,
      SIGDN_PARENTRELATIVE,
      SIGDN_PARENTRELATIVEFORUI
    };

    interface IShellItem : IUnknown {
        HRESULT BindToHandler(IBindCtx pbc, REFGUID bhid, REFIID riid, void **ppv);
        HRESULT GetParent(IShellItem *ppsi);
        HRESULT GetDisplayName(SIGDN  sigdnName, LPWSTR *ppszName);
        HRESULT GetAttributes(SFGAOF sfgaoMask, SFGAOF *psfgaoAttribs);
        HRESULT Compare(IShellItem psi, SICHINTF hint, int *piOrder);
    }

    extern(Windows) HRESULT SHCreateShellItem(LPCITEMIDLIST pidlParent, IShellFolder psfParent, LPCITEMIDLIST pidl, IShellItem *ppsi) nothrow @nogc;
    extern(Windows) LPITEMIDLIST ILCreateFromPath(PCTSTR pszPath);

    alias IFileOperationProgressSink = IUnknown;
    alias IOperationsProgressDialog = IUnknown;
    alias IPropertyChangeArray = IUnknown;

    immutable CLSID CLSID_FileOperation = {0x3ad05575,0x8857,0x4850,[0x92,0x77,0x11,0xb8,0x5b,0xdb,0x8e,0x9]};
    immutable IID IID_IFileOperation = {0x947aab5f,0xa5c,0x4c13,[0xb4,0xd6,0x4b,0xf7,0x83,0x6f,0xc9,0xf8]};

    interface IFileOperation : IUnknown
    {
        HRESULT Advise(IFileOperationProgressSink pfops, DWORD *pdwCookie);
        HRESULT Unadvise(DWORD dwCookie);
        HRESULT SetOperationFlags(DWORD dwOperationFlags);
        HRESULT SetProgressMessage(LPCWSTR pszMessage);
        HRESULT SetProgressDialog(IOperationsProgressDialog popd);
        HRESULT SetProperties (IPropertyChangeArray pproparray);
        HRESULT SetOwnerWindow(HWND hwndOwner);
        HRESULT ApplyPropertiesToItem(IShellItem psiItem);
        HRESULT ApplyPropertiesToItems (IUnknown punkItems);
        HRESULT RenameItem(IShellItem psiItem, LPCWSTR pszNewName, IFileOperationProgressSink pfopsItem);
        HRESULT RenameItems(IUnknown pUnkItems, LPCWSTR pszNewName);
        HRESULT MoveItem(IShellItem psiItem, IShellItem psiDestinationFolder, LPCWSTR pszNewName, IFileOperationProgressSink pfopsItem);
        HRESULT MoveItems(IUnknown punkItems, IShellItem psiDestinationFolder);
        HRESULT CopyItem(IShellItem psiItem, IShellItem psiDestinationFolder, LPCWSTR pszCopyName, IFileOperationProgressSink pfopsItem);
        HRESULT CopyItems(IUnknown punkItems, IShellItem psiDestinationFolder);
        HRESULT DeleteItem(IShellItem psiItem, IFileOperationProgressSink pfopsItem);
        HRESULT DeleteItems(IUnknown punkItems);
        HRESULT NewItem(IShellItem psiDestinationFolder, DWORD dwFileAttributes, LPCWSTR pszName, LPCWSTR pszTemplateName, IFileOperationProgressSink pfopsItem);
        HRESULT PerformOperations();
        HRESULT GetAnyOperationsAborted(BOOL *pfAnyOperationsAborted);
    }

    static @trusted string StrRetToString(ref scope STRRET strRet, LPITEMIDLIST pidl)
    {
        import std.string : fromStringz;
        switch (strRet.uType)
        {
        case STRRET_CSTR:
            return fromStringz(strRet.cStr.ptr).idup;
        case STRRET_OFFSET:
            return string.init;
        case STRRET_WSTR:
            char[MAX_PATH] szTemp;
            auto len = WideCharToMultiByte (CP_UTF8, 0, strRet.pOleStr, -1, szTemp.ptr, szTemp.sizeof, null, null);
            scope(exit) CoTaskMemFree(strRet.pOleStr);
            if (len)
                return szTemp[0..len-1].idup;
            else
                return string.init;
        default:
            return string.init;
        }
    }

    static @trusted wstring StrRetToWString(ref scope STRRET strRet, LPITEMIDLIST pidl)
    {
        switch (strRet.uType)
        {
        case STRRET_CSTR:
        {
            char[] cstr = fromStringz(strRet.cStr.ptr);
            wchar[] toReturn;
            toReturn.reserve(cstr.length);
            foreach(char c; cstr)
                toReturn ~= cast(wchar)c;
            return assumeUnique(toReturn);
        }
        case STRRET_WSTR:
            scope(exit) CoTaskMemFree(strRet.pOleStr);
            return strRet.pOleStr[0..lstrlenW(strRet.pOleStr)].idup;
        default:
            return wstring.init;
        }
    }

    static @trusted SysTime StrRetToSysTime(ref scope STRRET strRet, LPITEMIDLIST pidl)
    {
        auto str = StrRetToWString(strRet, pidl);
        if (str.length) {
            wchar[] temp;
            temp.reserve(str.length + 1);
            foreach(wchar c; str) {
                if (c != '\u200E' && c != '\u200F')
                    temp ~= c;
            }
            temp ~= '\0';
            DATE date;
            if(SUCCEEDED(VarDateFromStr(temp.ptr, LOCALE_USER_DEFAULT, 0, &date)))
            {
                SYSTEMTIME sysTime;
                if (VariantTimeToSystemTime(date, &sysTime))
                    return SYSTEMTIMEToSysTime(&sysTime);
            }
        }
        return SysTime.init;
    }

    @trusted static void henforce(HRESULT hres, lazy string msg = null, string file = __FILE__, size_t line = __LINE__)
    {
        if (FAILED(hres))
            throw new WindowsException(hres, msg, file, line);
    }

    @trusted static string getDisplayNameOf(IShellFolder folder, LPITEMIDLIST pidl)
    in {
        assert(folder);
        assert(pidl);
    }
    do {
        STRRET strRet;
        if (SUCCEEDED(folder.GetDisplayNameOf(pidl, SHGNO.SHGDN_NORMAL, &strRet)))
            return StrRetToString(strRet, pidl);
        return string.init;
    }

    @trusted static string getStringDetailOf(IShellFolder2 folder, LPITEMIDLIST pidl, uint index)
    in {
        assert(folder);
        assert(pidl);
    }
    do {
        SHELLDETAILS details;
        if(SUCCEEDED(folder.GetDetailsOf(pidl, index, &details)))
            return StrRetToString(details.str, pidl);
        return string.init;
    }

    @trusted static wstring getWStringDetailOf(IShellFolder2 folder, LPITEMIDLIST pidl, uint index)
    in {
        assert(folder);
        assert(pidl);
    }
    do {
        SHELLDETAILS details;
        if(SUCCEEDED(folder.GetDetailsOf(pidl, index, &details)))
            return StrRetToWString(details.str, pidl);
        return wstring.init;
    }

    @trusted static SysTime getSysTimeDetailOf(IShellFolder2 folder, LPITEMIDLIST pidl, uint index)
    in {
        assert(folder);
        assert(pidl);
    }
    do {
        SHELLDETAILS details;
        if(SUCCEEDED(folder.GetDetailsOf(pidl, index, &details)))
            return StrRetToSysTime(details.str, pidl);
        return SysTime.init;
    }

    @trusted static void RunVerb(string verb)(IShellFolder folder, LPITEMIDLIST pidl)
    in {
        assert(folder);
    }
    do {
        enforce(pidl !is null, "Empty trashcan item, can't run an operation");
        IContextMenu contextMenu;
        henforce(folder.GetUIObjectOf(null, 1, cast(LPCITEMIDLIST*)(&pidl), &IID_IContextMenu, null, cast(LPVOID *)&contextMenu), "Failed to get context menu ui object");
        assert(pidl);
        assert(contextMenu);
        scope(exit) contextMenu.Release();
        CMINVOKECOMMANDINFO ci;
        ci.fMask = CMIC_MASK_FLAG_NO_UI;
        ci.cbSize = CMINVOKECOMMANDINFO.sizeof;
        ci.lpVerb  = verb;
        henforce(contextMenu.InvokeCommand(&ci), "Failed to " ~ verb ~ " item");
    }

    @trusted static IFileOperation CreateFileOperation()
    {
        IFileOperation op;
        henforce(CoCreateInstance(&CLSID_FileOperation, null, CLSCTX_ALL, &IID_IFileOperation, cast(void**)&op), "Failed to create instance of IFileOperation");
        assert(op);
        return op;
    }

    @trusted static IShellItem CreateShellItem(IShellFolder folder, LPITEMIDLIST pidl)
    {
        IShellItem item;
        henforce(SHCreateShellItem(null, folder, pidl, &item), "Failed to get IShellItem");
        assert(item);
        return item;
    }

    @trusted static void RunDeleteOperation(IShellFolder folder, LPITEMIDLIST pidl)
    in {
        assert(folder);
    }
    do {
        enforce(pidl !is null, "Empty trashcan item, can't run a delete operation");
        IShellItem item = CreateShellItem(folder, pidl);
        scope(exit) item.Release();

        IFileOperation op = CreateFileOperation();
        scope(exit) op.Release();

        op.SetOperationFlags(FOF_NOCONFIRMATION|FOF_NOERRORUI|FOF_SILENT);
        op.DeleteItem(item, null);
        henforce(op.PerformOperations(), "Failed to perform file deletion operation");
    }

    @trusted static void RunRestoreOperation(IShellFolder2 folder, LPITEMIDLIST pidl)
    in {
        assert(folder);
    }
    do {
        enforce(pidl !is null, "Empty trashcan item, can't run a restore operation");

        import std.utf;
        wstring originalLocation = getWStringDetailOf(folder, pidl, 1);
        auto originalLocationZ = originalLocation.toUTF16z;

        auto originalLocationPidl = ILCreateFromPath(originalLocationZ);
        scope(exit) ILFree(originalLocationPidl);

        IShellItem originalLocationItem = CreateShellItem(null, originalLocationPidl);

        IShellItem item = CreateShellItem(folder, pidl);
        scope(exit) item.Release();

        IFileOperation op = CreateFileOperation();
        scope(exit) op.Release();

        op.SetOperationFlags(FOF_NOCONFIRMATION|FOF_NOERRORUI|FOF_SILENT);
        op.MoveItem(item, originalLocationItem, null, null);
        henforce(op.PerformOperations(), "Failed to perform file deletion operation");
    }
}

/// Interface to trashcan.
interface ITrashcan
{
    /// List items stored in trashcan.
    @trusted InputRange!TrashcanItem byItem();
    /// Restore item to its original location.
    @safe void restore(ref scope TrashcanItem item);
    /// Ditto
    @trusted final void restore(TrashcanItem item) {
        restore(item);
    }
    /// Erase item from trashcan.
    @safe void erase(ref scope TrashcanItem item);
    /// Ditto
    @trusted final erase(TrashcanItem item) {
        erase(item);
    }
    /// The name of trashcan (possibly localized).
    @property @safe string displayName() nothrow;
}

version(D_Ddoc)
{
    /**
     * Implementation of $(D ITrashcan). This class may have additional platform-dependent functions and different constructors.
     * This class is currently available only for $(BLUE Windows) and $(BLUE Freedesktop) (GNU/Linux, FreeBSD, etc.) platforms.
     */
    final class Trashcan : ITrashcan
    {
        ///
        @trusted this() {}
        /// Lazily list items stored in trashcan.
        @trusted InputRange!TrashcanItem byItem() {return null;}
        /**
         * Restore item to its original location.
         * Throws:
         *  $(B WindowsException) on Windows when the operation failed.$(BR)
         *  $(B FileException) on Posix when could not move the item to its original location or could not recreate original location directory.$(BR)
         *  $(B Exception) on other errors.
         */
        @safe void restore(ref scope TrashcanItem item) {}
        /**
         * Erase item from trashcan.
         * Throws:
         *  $(B WindowsException) on Windows when the operation failed.$(BR)
         *  $(B FileException) on Posix when could not delete the item.$(BR)
         *  $(B Exception) on other errors.
         */
        @safe void erase(ref scope TrashcanItem item) {}
        /**
         * The name of trashcan (possibly localized). Currently implemented only for Windows and KDE, and returns empty string on other platforms.
         * Returns:
         *  Name of trashcan as defined by system for the current user. Empty string if the name is unknown.
         */
        @property @safe string displayName() nothrow {return string.init;}

        static if (!is(typeof(IShellFolder2.init)))
        {
            static struct IShellFolder2 {}
        }
        /**
         * Windows-only function to get $(LINK2 https://docs.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-ishellfolder2, IShellFolder2) object associated with recycle bin.
         *
         * Note:
         *  If you want a returned object to outlive $(D Trashcan), you must call AddRef on it (and then Release when it's no longer needed).
         */
        @system @property @nogc IShellFolder2 recycleBin() nothrow {return IShellFolder2.init;}
    }
}
else version(Windows) final class Trashcan : ITrashcan
{
    @trusted this() {
        CoInitializeEx(null, COINIT.COINIT_APARTMENTTHREADED);
        IShellFolder desktop;
        LPITEMIDLIST pidlRecycleBin;

        henforce(SHGetDesktopFolder(&desktop), "Failed to get desktop shell folder");
        assert(desktop);
        scope(exit) desktop.Release();
        henforce(SHGetSpecialFolderLocation(null, CSIDL_BITBUCKET, &pidlRecycleBin), "Failed to get recycle bin location");
        assert(pidlRecycleBin);
        scope(exit) ILFree(pidlRecycleBin);

        henforce(desktop.BindToObject(pidlRecycleBin, null, &IID_IShellFolder2, cast(LPVOID *)&_recycleBin), "Failed to get recycle bin shell folder");
        assert(_recycleBin);
        collectException(getDisplayNameOf(desktop, pidlRecycleBin), _displayName);
    }

    @trusted ~this() {
        assert(_recycleBin);
        _recycleBin.Release();
        CoUninitialize();
    }

    private static struct ByItem
    {
        this(IShellFolder2 folder) {
            this.folder = folder;
            folder.AddRef();
            with(SHCONTF) henforce(folder.EnumObjects(null, SHCONTF_FOLDERS | SHCONTF_NONFOLDERS | SHCONTF_INCLUDEHIDDEN, &enumFiles), "Failed to enumerate objects in recycle bin");
            popFront();
        }
        this(this) {
            if (enumFiles)
                enumFiles.AddRef();
            if (folder)
                folder.AddRef();
        }
        ~this() {
            if (enumFiles)
                enumFiles.Release();
            if (folder)
                folder.Release();
        }
        TrashcanItem front() {
            return current;
        }
        TrashcanItem moveFront() {
            import std.algorithm.mutation : move;
            return move(current);
        }
        void popFront() {
            LPITEMIDLIST pidl;
            if (enumFiles.Next(1, &pidl, null) == S_FALSE) {
                atTheEnd = true;
            } else {
                assert(pidl);
                ULONG attributes = SFGAOF.SFGAO_FOLDER;
                folder.GetAttributesOf(1,cast(LPCITEMIDLIST *)&pidl,&attributes);
                string fileName = getDisplayNameOf(folder, pidl);
                string extension = getStringDetailOf(folder, pidl, 166);
                SysTime deletionTime = getSysTimeDetailOf(folder, pidl, 2);
                // The returned name may or may not contain the extension depending on the view parameters of the recycle bin folder
                if (fileName.extension != extension)
                    fileName ~= extension;
                current = TrashcanItem(fileName, !!(attributes & SFGAOF.SFGAO_FOLDER), deletionTime, pidl);
            }
        }
        bool empty() {
            return atTheEnd;
        }
    private:
        IShellFolder2 folder;
        IEnumIDList enumFiles;
        TrashcanItem current;
        bool atTheEnd;
    }

    @trusted InputRange!TrashcanItem byItem() {
        return inputRangeObject(ByItem(_recycleBin));
    }

    private @trusted void trustedRestore(ref scope TrashcanItem item) {
        //RunVerb!"undelete"(_recycleBin, item.itemIdList);
        RunRestoreOperation(_recycleBin, item.itemIdList);
    }
    @safe void restore(ref scope TrashcanItem item) {
        trustedRestore(item);
    }
    private @trusted void trustedErase(ref scope TrashcanItem item) {
        //RunVerb!"delete"(_recycleBin, item.itemIdList);
        RunDeleteOperation(_recycleBin, item.itemIdList);
    }
    @safe void erase(ref scope TrashcanItem item) {
        trustedErase(item);
    }
    @property @safe string displayName() nothrow {
        return _displayName;
    }
    @property @system @nogc IShellFolder2 recycleBin() nothrow {
        return _recycleBin;
    }
private:
    string _displayName;
    IShellFolder2 _recycleBin;
} else static if (isFreedesktop)
{
    final class Trashcan : ITrashcan
    {
        private @safe static bool isDirNothrow(string path) nothrow {
            bool isDirectory;
            if (collectException(path.isDir, isDirectory) is null)
                return isDirectory;
            return false;
        }

        @safe this() {}

        import std.typecons : Tuple;

        @trusted InputRange!TrashcanItem byItem() {
            import std.algorithm.iteration : cache, map, joiner, filter;
            alias Tuple!(string, "base", string, "info", string, "files", string, "root") TrashLocation;
            return inputRangeObject(standardTrashBasePaths().map!(trashDir => TrashLocation(trashDir.base, buildPath(trashDir.base, "info"), buildPath(trashDir.base, "files"), trashDir.root)).filter!(t => isDirNothrow(t.info) && isDirNothrow(t.files)).map!(delegate(TrashLocation trash) {
                InputRange!TrashcanItem toReturn;
                try {
                    toReturn = inputRangeObject(dirEntries(trash.info, SpanMode.shallow, false).filter!(entry => entry.extension == ".trashinfo").map!(delegate(DirEntry entry) {
                        string trashedFile = buildPath(trash.files, entry.baseName.stripExtension);
                        try {
                            if (exists(trashedFile)) {
                                import inilike.read;

                                string path;
                                SysTime deletionTime;

                                auto onGroup = delegate ActionOnGroup(string groupName) {
                                    if (groupName == "Trash Info")
                                        return ActionOnGroup.stopAfter;
                                    return ActionOnGroup.skip;
                                };
                                auto onKeyValue = delegate void(string key, string value, string groupName) {
                                    if (groupName == "Trash Info")
                                    {
                                        if (key == "Path")
                                            path = value;
                                        else if (key == "DeletionDate")
                                            collectException(SysTime.fromISOExtString(value), deletionTime);
                                    }
                                };
                                readIniLike(iniLikeFileReader(entry.name), null, onGroup, onKeyValue, null);

                                if (path.length) {
                                    path = path.decode();
                                    string restorePath;
                                    if (path.isAbsolute)
                                        restorePath = path;
                                    else
                                        restorePath = buildPath(trash.root, path);
                                    return TrashcanItem(restorePath, trashedFile.isDir, deletionTime, entry.name, trashedFile);
                                }
                            }
                        } catch(Exception e) {}
                        return TrashcanItem.init;
                    }).cache.filter!(item => item.restorePath.length));
                } catch(Exception e) {
                    toReturn = inputRangeObject(TrashcanItem[].init);
                }
                return toReturn;
            }).cache.joiner);
        }

        @safe void restore(ref scope TrashcanItem item) {
            mkdirRecurse(item.restorePath.dirName);
            rename(item.trashedPath, item.restorePath);
            collectException(remove(item.trashInfoPath));
        }
        @safe void erase(ref scope TrashcanItem item) {
            static @trusted void trustedErase(string path)
            {
                if (path.isDir)
                    rmdirRecurse(path);
                else
                    remove(path);
            }
            trustedErase(item.trashedPath);
            collectException(remove(item.trashInfoPath));
        }
        @property @safe string displayName() nothrow {
            if (!_triedToRetrieveName) {
                _triedToRetrieveName = true;

                static @safe string currentLocale() nothrow
                {
                    import std.process : environment;
                    try {
                        return environment.get("LC_ALL", environment.get("LC_MESSAGES", environment.get("LANG")));
                    } catch(Exception e) {
                        return null;
                    }
                }

                static @trusted string readTrashName(scope const(string)[] desktopFiles, scope string locale) nothrow {
                    foreach(path; desktopFiles) {
                        if (!path.exists)
                            continue;
                        try {
                            import inilike.read;
                            import inilike.common;

                            string name;
                            string bestLocale;

                            auto onGroup = delegate ActionOnGroup(string groupName) {
                                if (groupName == "Desktop Entry")
                                    return ActionOnGroup.stopAfter;
                                return ActionOnGroup.skip;
                            };
                            auto onKeyValue = delegate void(string key, string value, string groupName) {
                                if (groupName == "Desktop Entry")
                                {
                                    auto keyAndLocale = separateFromLocale(key);
                                    if (keyAndLocale[0] == "Name")
                                    {
                                        auto lv = selectLocalizedValue(locale, keyAndLocale[1], value, bestLocale, name);
                                        bestLocale = lv[0];
                                        name = lv[1].unescapeValue();
                                    }
                                }
                            };
                            readIniLike(iniLikeFileReader(path), null, onGroup, onKeyValue, null);
                            if (name.length)
                                return name;
                        } catch(Exception e) {}
                    }
                    return string.init;
                }

                const locale = currentLocale();
                _displayName = readTrashName(xdgAllDataDirs("kio_desktop/directory.trash"), locale);
                if (!_displayName.length) {
                    _displayName = readTrashName(xdgAllDataDirs("kde4/apps/kio_desktop/directory.trash"), locale);
                }
            }
            /+
            On GNOME it can be read from nautilus translation file (.mo).
            +/
            return _displayName;
        }
    private:
        alias Tuple!(string, "base", string, "root") TrashRoot;
        @trusted static TrashRoot[] standardTrashBasePaths() {
            TrashRoot[] trashBasePaths;
            import core.sys.posix.unistd;

            string homeTrashPath = xdgDataHome("Trash");
            string homeTrashTopDir;
            if (homeTrashPath.length && homeTrashPath.isAbsolute && isDirNothrow(homeTrashPath)) {
                homeTrashTopDir = homeTrashPath.topDir;
                trashBasePaths ~= TrashRoot(homeTrashPath, homeTrashTopDir);
            }

            auto userId = getuid();
            auto volumes = mountedVolumes();
            foreach(volume; volumes) {
                if (!volume.isValid)
                    continue;
                if (homeTrashTopDir == volume.path)
                    continue;
                string diskTrash;
                string userTrash;
                if (collectException(checkDiskTrash(volume.path), diskTrash) is null) {
                    userTrash = userTrashSubdir(diskTrash, userId);
                    if (isDirNothrow(userTrash))
                        trashBasePaths ~= TrashRoot(userTrash, volume.path);
                }
                userTrash = userTrashDir(volume.path, userId);
                if (isDirNothrow(userTrash))
                    trashBasePaths ~= TrashRoot(userTrash, volume.path);
            }
            return trashBasePaths;
        }
        string _displayName;
        bool _triedToRetrieveName;
    }
}
