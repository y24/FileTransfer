// Win32 API wrappers used by FileTransfer.
// Keep this file ASCII-only: Add-Type does not reliably detect UTF-8 without BOM.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security;

namespace FileTransfer
{
    public static class Native
    {
        const int RESOURCETYPE_ANY = 0;
        const int RESOURCE_CONNECTED = 1;
        const int ERROR_MORE_DATA = 234;
        const int CRED_TYPE_DOMAIN_PASSWORD = 2;
        const int CRED_PERSIST_LOCAL_MACHINE = 2;
        const uint INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
        const int GWL_STYLE = -16;
        const int WS_MAXIMIZEBOX = 0x00010000;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct NETRESOURCE
        {
            public int dwScope;
            public int dwType;
            public int dwDisplayType;
            public int dwUsage;
            public string lpLocalName;
            public string lpRemoteName;
            public string lpComment;
            public string lpProvider;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFileAttributesW(string path);

        [DllImport("kernel32.dll")]
        static extern uint GetOEMCP();

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool GetDiskFreeSpaceExW(string directory, out ulong freeBytesAvailable, out ulong totalBytes, out ulong totalFreeBytes);

        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        static extern int WNetOpenEnum(int scope, int type, int usage, IntPtr netResource, out IntPtr handle);

        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        static extern int WNetEnumResource(IntPtr handle, ref int count, IntPtr buffer, ref int bufferSize);

        [DllImport("mpr.dll")]
        static extern int WNetCloseEnum(IntPtr handle);

        [DllImport("user32.dll", SetLastError = true)]
        static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", SetLastError = true)]
        static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        static extern int WNetAddConnection2(ref NETRESOURCE netResource, IntPtr password, string userName, int flags);

        [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
        static extern int WNetCancelConnection2(string name, int flags, bool force);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll")]
        static extern void CredFree(IntPtr buffer);

        // 0 when the path is accessible, otherwise the Win32 error code (5, 53, 67, 1326, ...).
        public static int GetPathError(string path)
        {
            uint attributes = GetFileAttributesW(path);
            return attributes == INVALID_FILE_ATTRIBUTES ? Marshal.GetLastWin32Error() : 0;
        }

        // Free bytes available to the current user on the volume that contains the directory
        // (local path or \\host\share\), or -1 when it cannot be determined.
        public static long GetFreeBytes(string directory)
        {
            ulong free, total, totalFree;
            if (!GetDiskFreeSpaceExW(directory, out free, out total, out totalFree)) return -1;
            return free > (ulong)long.MaxValue ? long.MaxValue : (long)free;
        }

        // Network connections of the current user (what "net use" lists), as "local|remote".
        // local is "" for connections without a drive letter.
        public static string[] GetConnections()
        {
            List<string> result = new List<string>();
            IntPtr handle;
            if (WNetOpenEnum(RESOURCE_CONNECTED, RESOURCETYPE_ANY, 0, IntPtr.Zero, out handle) != 0) return result.ToArray();
            int bufferSize = 16384;
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try
            {
                int structSize = Marshal.SizeOf(typeof(NETRESOURCE));
                while (true)
                {
                    int count = -1;
                    int size = bufferSize;
                    int code = WNetEnumResource(handle, ref count, buffer, ref size);
                    if (code == ERROR_MORE_DATA)
                    {
                        Marshal.FreeHGlobal(buffer);
                        bufferSize = Math.Max(size, bufferSize * 2);
                        buffer = Marshal.AllocHGlobal(bufferSize);
                        continue;
                    }
                    if (code != 0) break;
                    for (int i = 0; i < count; i++)
                    {
                        IntPtr item = new IntPtr(buffer.ToInt64() + (long)i * structSize);
                        NETRESOURCE resource = (NETRESOURCE)Marshal.PtrToStructure(item, typeof(NETRESOURCE));
                        result.Add((resource.lpLocalName ?? "") + "|" + (resource.lpRemoteName ?? ""));
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
                WNetCloseEnum(handle);
            }
            return result.ToArray();
        }

        // Code page robocopy uses when its output is redirected.
        public static int OemCodePage()
        {
            return (int)GetOEMCP();
        }

        // Connects to \\host\share with explicit credentials. Returns 0 or a Win32 error code.
        // The password never becomes a managed string.
        public static int AddConnection(string remoteName, string userName, SecureString password)
        {
            NETRESOURCE resource = new NETRESOURCE();
            resource.dwType = RESOURCETYPE_ANY;
            resource.lpRemoteName = remoteName;
            IntPtr passwordPtr = IntPtr.Zero;
            try
            {
                if (password != null) passwordPtr = Marshal.SecureStringToGlobalAllocUnicode(password);
                return WNetAddConnection2(ref resource, passwordPtr, userName, 0);
            }
            finally
            {
                if (passwordPtr != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(passwordPtr);
            }
        }

        public static int CancelConnection(string remoteName, bool force)
        {
            return WNetCancelConnection2(remoteName, 0, force);
        }

        // Saves a "Windows credential" (domain password) that the SMB client uses automatically.
        public static int WriteCredential(string target, string userName, SecureString password)
        {
            CREDENTIAL credential = new CREDENTIAL();
            credential.Type = CRED_TYPE_DOMAIN_PASSWORD;
            credential.TargetName = target;
            credential.UserName = userName;
            credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
            IntPtr blob = IntPtr.Zero;
            try
            {
                blob = Marshal.SecureStringToGlobalAllocUnicode(password);
                credential.CredentialBlob = blob;
                credential.CredentialBlobSize = password.Length * 2;
                return CredWrite(ref credential, 0) ? 0 : Marshal.GetLastWin32Error();
            }
            finally
            {
                if (blob != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(blob);
            }
        }

        // User name of the saved credential for target, or null.
        public static string ReadCredentialUser(string target)
        {
            IntPtr pointer;
            if (!CredRead(target, CRED_TYPE_DOMAIN_PASSWORD, 0, out pointer)) return null;
            try
            {
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(pointer, typeof(CREDENTIAL));
                return credential.UserName;
            }
            finally
            {
                CredFree(pointer);
            }
        }

        public static bool DeleteCredential(string target)
        {
            return CredDelete(target, CRED_TYPE_DOMAIN_PASSWORD, 0);
        }

        public static void RemoveMaximizeBox(IntPtr hwnd)
        {
            int style = GetWindowLong(hwnd, GWL_STYLE);
            SetWindowLong(hwnd, GWL_STYLE, style & ~WS_MAXIMIZEBOX);
        }
    }
}
