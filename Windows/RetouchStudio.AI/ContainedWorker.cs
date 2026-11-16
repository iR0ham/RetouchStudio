using System.Diagnostics;
using System.Runtime.InteropServices;

namespace RetouchStudio.AI;

/// <summary>
/// Starts the worker inside a Job Object configured with kill-on-close, so a
/// host crash cannot leave an orphaned runtime behind.
/// </summary>
public sealed class ContainedWorker : IDisposable
{
    private readonly Process _process;
    private IntPtr _job;
    private Task? _logPump;

    private ContainedWorker(Process process, IntPtr job)
    {
        _process = process;
        _job = job;
    }

    public int Pid => _process.Id;
    public bool HasExited => _process.HasExited;
    public bool ContainedExited { get; private set; }

    public static ContainedWorker Start(string executable, IEnumerable<string> arguments,
        string? workingDirectory = null, string? errorLog = null)
    {
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            RedirectStandardError = errorLog is not null,
            WorkingDirectory = workingDirectory ?? Environment.CurrentDirectory,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);

        var job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
            throw new InvalidOperationException("CreateJobObject failed");

        Process? process = null;
        try
        {
            var limits = new JobObjectExtendedLimitInformation
            {
                BasicLimitInformation = new JobObjectBasicLimitInformation
                {
                    LimitFlags = JobObjectLimitKillOnJobClose,
                },
            };
            var size = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
            var pointer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(limits, pointer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformationClass,
                        pointer, (uint)size))
                {
                    throw new InvalidOperationException("SetInformationJobObject failed");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }

            process = Process.Start(info)
                ?? throw new InvalidOperationException("the worker process did not start");
            if (!AssignProcessToJobObject(job, process.Handle))
            {
                throw new InvalidOperationException(
                    "AssignProcessToJobObject failed; the worker would not be contained");
            }

            var contained = new ContainedWorker(process, job);
            job = IntPtr.Zero;
            if (errorLog is not null)
            {
                var writer = new StreamWriter(errorLog, append: false) { AutoFlush = true };
                contained._logPump = Task.Run(async () =>
                {
                    var buffer = new char[4096];
                    int read;
                    while ((read = await process.StandardError.ReadAsync(buffer)) > 0)
                    {
                        await writer.WriteAsync(buffer.AsMemory(0, read));
                    }
                });
            }
            return contained;
        }
        catch
        {
            process?.Kill(entireProcessTree: true);
            if (job != IntPtr.Zero) CloseHandle(job);
            throw;
        }
    }

    public bool WaitForExit(TimeSpan timeout) => _process.WaitForExit((int)timeout.TotalMilliseconds);

    public void Dispose()
    {
        if (_job != IntPtr.Zero)
        {
            CloseHandle(_job);
            _job = IntPtr.Zero;
        }
        if (!_process.HasExited)
        {
            _process.WaitForExit(5000);
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                _process.WaitForExit(5000);
            }
        }
        ContainedExited = _process.HasExited;
        _logPump?.Wait(TimeSpan.FromSeconds(2));
        _process.Dispose();
    }

    private const uint JobObjectLimitKillOnJobClose = 0x2000;
    private const int JobObjectExtendedLimitInformationClass = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass,
        IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
