using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PveImageBuilder {
    public sealed class BuildProcess : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
            public long PerProcessTime, PerJobTime;
            public uint LimitFlags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        readonly ConcurrentQueue<string> output = new ConcurrentQueue<string>();
        readonly Process process = new Process();
        IntPtr job;
        public BuildProcess(string executable, string arguments, string directory) {
            job=CreateJobObject(IntPtr.Zero,null);
            if (job==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                var limits=new ExtendedLimits();
                limits.Basic.LimitFlags=0x2000; // Kill only this job's processes on close.
                if (!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits)))) throw new Win32Exception(Marshal.GetLastWin32Error());
                process.StartInfo=new ProcessStartInfo(executable,arguments) { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true, WorkingDirectory=directory, StandardOutputEncoding=new System.Text.UTF8Encoding(false), StandardErrorEncoding=new System.Text.UTF8Encoding(false) };
                process.OutputDataReceived += (sender,e) => { if(e.Data!=null) output.Enqueue(e.Data); };
                process.ErrorDataReceived += (sender,e) => { if(e.Data!=null) output.Enqueue(e.Data); };
                process.Start();
                if (!AssignProcessToJobObject(job,process.Handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
            } catch {
                try { if(!process.HasExited) process.Kill(); } catch {}
                CloseHandle(job); job=IntPtr.Zero;
                process.Dispose();
                throw;
            }
        }
        public string[] ReadOutput() { var lines=new System.Collections.Generic.List<string>(); string line; while(output.TryDequeue(out line)) lines.Add(line); return lines.ToArray(); }
        public bool HasExited { get { return process.HasExited; } }
        public int ExitCode { get { return process.ExitCode; } }
        public int Id { get { return process.Id; } }
        public void Wait() { process.WaitForExit(); }
        public void Cancel() {
            if (!TerminateJobObject(job,130)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!process.WaitForExit(10000)) throw new TimeoutException("Build worker did not stop.");
            process.WaitForExit();
        }
        public void Dispose() { if(job!=IntPtr.Zero) { CloseHandle(job); job=IntPtr.Zero; } process.Dispose(); }
    }
}
