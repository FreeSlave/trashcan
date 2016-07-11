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

import isfreedesktop;

static if (isFreedesktop)
{
private:
    import std.exception;
    import std.format : format;
    @trusted string numberedBaseName(string path, uint number) {
        return format("%s %s%s", path.baseName.stripExtension, number, path.extension);
    }
    
    unittest
    {
        assert(numberedBaseName("/root/file.ext", 1) == "file 1.ext");
        assert(numberedBaseName("/root/file", 2) == "file 2");
    }
    
    @trusted string escapeValue(string value) pure {
        return value.replace("\\", `\\`).replace("\n", `\n`).replace("\r", `\r`).replace("\t", `\t`);
    }
    
    import core.sys.posix.sys.types;
    import core.sys.posix.sys.stat;
    import core.sys.posix.unistd;
    
    @trusted string topDir(string path)
    in {
        assert(path.isAbsolute);
    }
    body {
        auto current = path;
        stat_t currentStat;
        if (stat(current.toStringz, &currentStat) != 0) {
            return null;
        }
        stat_t parentStat;
        while(current != "/") {
            string parent = current.dirName;
            if (stat(parent.toStringz, &parentStat) != 0) {
                return null;
            }
            if (currentStat.st_dev != parentStat.st_dev) {
                return current;
            }
            current = parent;
        }
        return current;
    }
    
    @trusted string checkDiskTrash(string topdir)
    in {
        assert(topdir.length);
    }
    body {
        string trashDir = buildPath(topdir, ".Trash");
        stat_t trashStat;
        if (stat(trashDir.toStringz, &trashStat) != 0) {
            return null;
        }
        if (S_ISLNK(trashStat.st_mode) || ((trashStat.st_mode & S_ISVTX) != 0)) {
            return null;
        }
        return trashDir;
    }
    
    @trusted string ensureUserTrashDir(string trashDir)
    {
        string userTrashDir = buildPath(trashDir, format("%s", getuid()));
        bool ok;
        collectException(userTrashDir.isDir(), ok);
        if (!ok) {
            mkdirRecurse(userTrashDir);
        }
        return userTrashDir;
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
    
    extern(C) @nogc @system OSStatus _dummy_FSPathMakeRefWithOptions(const(char)* path, OptionBits, FSRef*, Boolean*) nothrow {return 0;}
    extern(C) @nogc @system OSStatus _dummy_FSMoveObjectToTrashSync(const(FSRef)*, FSRef*, OptionBits) nothrow {return 0;}
}

/**
 * Move file or directory to trash can. 
 * Params:
 *  path = Path of item to remove. Must be absolute.
 * Throws:
 *  Exception when given path is not absolute or does not exist or some error occured during operation.
 */
@trusted void moveToTrash(string path)
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
            wchar[1024] msg;
            auto len = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM, null, r, 0, msg.ptr, msg.length - 1, null);
            
            if (len) {
                throw new Exception(msg[0..len].toUTF8().stripRight);
            } else {
                throw new Exception("File deletion error");
            }
        }
    } else version(OSX) {
        import std.exception;
        
        void* handle = dlopen("CoreServices.framework/Versions/A/CoreServices", RTLD_NOW | RTLD_LOCAL);
        if (handle !is null) {
            scope(exit) dlclose(handle);
            
            auto ptrFSPathMakeRefWithOptions = cast(typeof(&_dummy_FSPathMakeRefWithOptions))dlsym(handle, "FSPathMakeRefWithOptions");
            if (ptrFSPathMakeRefWithOptions is null) {
                throw new Exception(fromStringz(dlerror()).idup);
            }
            
            auto ptrFSMoveObjectToTrashSync = cast(typeof(&_dummy_FSMoveObjectToTrashSync))dlsym(handle, "FSMoveObjectToTrashSync");
            if (ptrFSMoveObjectToTrashSync is null) {
                throw new Exception(fromStringz(dlerror()).idup);
            }
            
            FSRef source;
            enforce(ptrFSPathMakeRefWithOptions(toStringz(path), 1, &source, null) == 0, "Could not make FSRef from path");
            FSRef target;
            enforce(ptrFSMoveObjectToTrashSync(&source, &target, 0) == 0, "Could not move path to trash");
        } else {
            throw new Exception(fromStringz(dlerror()).idup);
        }
    } else {
        static if (isFreedesktop) {
            import xdgpaths;
            
            string trashInfoDir = xdgDataHome("Trash/info", true);
            if (!trashInfoDir.length) {
                throw new Exception("Could not access trash info folder");
            }
            string trashFilePathsDir = xdgDataHome("Trash/files", true);
            if (!trashFilePathsDir.length) {
                throw new Exception("Could not access trash files folder");
            }
            
            string trashInfoPath = buildPath(trashInfoDir, path.baseName ~ ".trashinfo");
            string trashFilePath = buildPath(trashFilePathsDir, path.baseName);
            uint number = 1;
            
            while(trashInfoPath.exists || trashFilePath.exists) {
                string baseName = numberedBaseName(path, number);
                trashInfoPath = buildPath(trashInfoDir, baseName ~ ".trashinfo");
                trashFilePath = buildPath(trashFilePathsDir, baseName);
                number++;
            }
            
            import std.datetime;
            auto currentTime = Clock.currTime;
            currentTime.fracSecs = Duration.zero;
            string contents = format("[Trash Info]\nPath=%s\nDeletionDate=%s\n", path.escapeValue(), currentTime.toISOExtString());
            write(trashInfoPath, contents);
            path.rename(trashFilePath);
        } else {
            static assert("Unsupported platform");
        }
    }
}
