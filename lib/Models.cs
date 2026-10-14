// View model for one row of the file list.
// Keep this file ASCII-only (Japanese text is written as \u escapes).
using System;
using System.ComponentModel;

namespace FileTransfer
{
    public class FileItem : INotifyPropertyChanged
    {
        long size = -1;
        int fileCount = -1;
        string state = "";
        double progress;

        public FileItem(string path, bool isFolder)
        {
            Path = path;
            IsFolder = isFolder;
            Name = System.IO.Path.GetFileName(path.TrimEnd('\\'));
        }

        public event PropertyChangedEventHandler PropertyChanged;

        public string Path { get; private set; }
        public string Name { get; private set; }
        public bool IsFolder { get; private set; }

        // -1 while a folder size is still being calculated.
        public long Size
        {
            get { return size; }
            set { size = value; Notify("Size"); Notify("SizeText"); }
        }

        public int FileCount
        {
            get { return fileCount; }
            set { fileCount = value; Notify("FileCount"); Notify("ToolTipText"); }
        }

        // "" | "cur" | "done"
        public string State
        {
            get { return state; }
            set { state = value ?? ""; Notify("State"); Notify("Glyph"); }
        }

        // 0..1, progress of this item while it is being copied.
        public double Progress
        {
            get { return progress; }
            set { progress = Math.Max(0, Math.Min(1, value)); Notify("Progress"); }
        }

        public string SizeText
        {
            // "Calculating..." (Japanese)
            get { return size < 0 ? "\u8A08\u7B97\u4E2D\u2026" : FormatSize(size); }
        }

        public string ToolTipText
        {
            // "<path>\n<count> files" (Japanese)
            get { return IsFolder && fileCount >= 0 ? Path + "\n" + fileCount.ToString("N0") + " \u30D5\u30A1\u30A4\u30EB" : Path; }
        }

        // Segoe Fluent Icons / Segoe MDL2 Assets glyphs.
        public string Glyph
        {
            get
            {
                if (state == "done") return "\uE73E";   // CheckMark
                if (state == "cur") return "\uE898";    // Upload
                return IsFolder ? "\uE8B7" : "\uE7C3";  // Folder / Page
            }
        }

        public static string FormatSize(long bytes)
        {
            if (bytes < 0) return "";
            if (bytes == 0) return "0 KB";
            if (bytes < 1024L * 1024) return Math.Max(1, (long)Math.Ceiling(bytes / 1024.0)).ToString("N0") + " KB";
            if (bytes < 1024L * 1024 * 1024) return (bytes / 1048576.0).ToString("N1") + " MB";
            return (bytes / 1073741824.0).ToString("N2") + " GB";
        }

        void Notify(string name)
        {
            PropertyChangedEventHandler handler = PropertyChanged;
            if (handler != null) handler(this, new PropertyChangedEventArgs(name));
        }
    }
}
