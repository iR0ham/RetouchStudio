using System.Runtime.InteropServices;

namespace RetouchStudio.Core.Interop;

/// <summary>
/// The engine-owned byte range from <c>studioscore_core.h</c>. Two machine
/// words, asserted from C by <c>Tests/ABI/abi_tests.c</c>.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct ScCoreBytes
{
    public IntPtr Pointer;
    public nuint Length;
}

/// <summary>
/// The StudioCore C ABI v0. Everything here is a thin, ownership-correct
/// wrapper: every engine buffer is copied out and released exactly once, and a
/// non-zero status becomes a <see cref="StudioCoreException"/> carrying the
/// stable error code.
/// </summary>
public static class StudioCoreApi
{
    public const uint SupportedAbi = 1;

    private const string Library = "studioscore_core";
    private const CallingConvention Convention = CallingConvention.Cdecl;

    [DllImport(Library, CallingConvention = Convention)]
    private static extern uint sc_core_abi_version();

    [DllImport(Library, CallingConvention = Convention)]
    private static extern void sc_core_bytes_release(ref ScCoreBytes bytes);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_project_read(byte[] bytes, nuint length,
                                              out ScCoreBytes document,
                                              out ScCoreBytes context,
                                              out ScCoreBytes error);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_project_write(byte[] document, nuint documentLength,
                                               byte[] context, nuint contextLength,
                                               out ScCoreBytes project,
                                               out ScCoreBytes error);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_render_plan(byte[] request, nuint requestLength,
                                             byte[] source, nuint sourceLength,
                                             out ScCoreBytes plan,
                                             out ScCoreBytes error);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_history_create(byte[] state, nuint stateLength,
                                                out IntPtr history,
                                                out ScCoreBytes error);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern void sc_history_destroy(IntPtr history);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_history_commit(IntPtr history,
                                                byte[] state, nuint stateLength);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_history_undo(IntPtr history,
                                              byte[] current, nuint currentLength,
                                              out ScCoreBytes state);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_history_redo(IntPtr history,
                                              byte[] current, nuint currentLength,
                                              out ScCoreBytes state);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_history_flags(IntPtr history,
                                               byte[] current, nuint currentLength,
                                               out int canUndo, out int canRedo);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_history_mark_clean(IntPtr history,
                                                    byte[] state, nuint stateLength);

    [DllImport(Library, CallingConvention = Convention)]
    private static extern int sc_history_is_dirty(IntPtr history,
                                                  byte[] current, nuint currentLength,
                                                  out int dirty);

    /// <summary>
    /// Fails fast when the DLL on disk is not the ABI this host was built for.
    /// A mismatch is a packaging defect, not a document the owner can fix.
    /// </summary>
    public static void VerifyAbi()
    {
        var version = sc_core_abi_version();
        if (version != SupportedAbi)
        {
            throw new InvalidOperationException(
                $"studioscore_core.dll speaks ABI {version}; this host needs {SupportedAbi}");
        }
    }

    public static (byte[] Document, byte[] Context) ReadProject(byte[] file)
    {
        var status = (StudioCoreStatus)sc_project_read(file, (nuint)file.Length,
                                                      out var document, out var context,
                                                      out var error);
        var documentBytes = Take(ref document);
        var contextBytes = Take(ref context);
        if (status != StudioCoreStatus.Ok)
        {
            throw Failure(status, ref error);
        }
        return (documentBytes, contextBytes);
    }

    public static byte[] WriteProject(byte[] document, byte[] context)
    {
        var status = (StudioCoreStatus)sc_project_write(document, (nuint)document.Length,
                                                        context, (nuint)context.Length,
                                                        out var project, out var error);
        var projectBytes = Take(ref project);
        if (status != StudioCoreStatus.Ok)
        {
            throw Failure(status, ref error);
        }
        return projectBytes;
    }

    public static byte[] RenderPlan(byte[] request, byte[] source)
    {
        var status = (StudioCoreStatus)sc_render_plan(request, (nuint)request.Length,
                                                      source, (nuint)source.Length,
                                                      out var plan, out var error);
        var planBytes = Take(ref plan);
        if (status != StudioCoreStatus.Ok)
        {
            throw Failure(status, ref error);
        }
        return planBytes;
    }

    internal static IntPtr CreateHistory(byte[] state)
    {
        var status = (StudioCoreStatus)sc_history_create(state, (nuint)state.Length,
                                                         out var history, out var error);
        if (status != StudioCoreStatus.Ok)
        {
            throw Failure(status, ref error);
        }
        return history;
    }

    internal static void DestroyHistory(IntPtr history) => sc_history_destroy(history);

    internal static void Commit(IntPtr history, byte[] state)
    {
        var status = (StudioCoreStatus)sc_history_commit(history, state, (nuint)state.Length);
        if (status != StudioCoreStatus.Ok)
        {
            throw new StudioCoreException(status, "internal", "the history commit failed");
        }
    }

    internal static byte[]? Undo(IntPtr history, byte[] current)
    {
        var status = (StudioCoreStatus)sc_history_undo(history, current, (nuint)current.Length,
                                                       out var state);
        var bytes = Take(ref state);
        if (status != StudioCoreStatus.Ok)
        {
            throw new StudioCoreException(status, "internal", "the history undo failed");
        }
        return bytes.Length == 0 ? null : bytes;
    }

    internal static byte[]? Redo(IntPtr history, byte[] current)
    {
        var status = (StudioCoreStatus)sc_history_redo(history, current, (nuint)current.Length,
                                                       out var state);
        var bytes = Take(ref state);
        if (status != StudioCoreStatus.Ok)
        {
            throw new StudioCoreException(status, "internal", "the history redo failed");
        }
        return bytes.Length == 0 ? null : bytes;
    }

    internal static (bool CanUndo, bool CanRedo) Flags(IntPtr history, byte[] current)
    {
        var status = (StudioCoreStatus)sc_history_flags(history, current, (nuint)current.Length,
                                                        out var canUndo, out var canRedo);
        if (status != StudioCoreStatus.Ok)
        {
            throw new StudioCoreException(status, "internal", "the history flags failed");
        }
        return (canUndo != 0, canRedo != 0);
    }

    internal static void MarkClean(IntPtr history, byte[] state)
    {
        var status = (StudioCoreStatus)sc_history_mark_clean(history, state, (nuint)state.Length);
        if (status != StudioCoreStatus.Ok)
        {
            throw new StudioCoreException(status, "internal", "the clean baseline was refused");
        }
    }

    internal static bool IsDirty(IntPtr history, byte[] current)
    {
        var status = (StudioCoreStatus)sc_history_is_dirty(history, current, (nuint)current.Length,
                                                           out var dirty);
        if (status != StudioCoreStatus.Ok)
        {
            throw new StudioCoreException(status, "internal", "the dirty check failed");
        }
        return dirty != 0;
    }

    /// <summary>
    /// Copies an engine buffer out and releases it. The ABI zeroes the
    /// descriptor, so the release is safe exactly once and never on host input.
    /// </summary>
    private static byte[] Take(ref ScCoreBytes bytes)
    {
        try
        {
            if (bytes.Pointer == IntPtr.Zero || bytes.Length == 0)
            {
                return Array.Empty<byte>();
            }
            var copy = new byte[(int)bytes.Length];
            Marshal.Copy(bytes.Pointer, copy, 0, copy.Length);
            return copy;
        }
        finally
        {
            sc_core_bytes_release(ref bytes);
        }
    }

    private static StudioCoreException Failure(StudioCoreStatus status, ref ScCoreBytes error)
    {
        var payload = Take(ref error);
        return ErrorPayload.Parse(status, payload);
    }
}
