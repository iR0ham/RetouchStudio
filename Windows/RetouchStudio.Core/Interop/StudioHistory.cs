namespace RetouchStudio.Core.Interop;

/// <summary>
/// The undo history for one open document. States are compared byte for byte,
/// so a host must hand in the same canonical encoding every time; the session
/// layer below does that.
/// </summary>
public sealed class StudioHistory : IDisposable
{
    private IntPtr _handle;

    private StudioHistory(IntPtr handle) => _handle = handle;

    public static StudioHistory Create(byte[] state) => new(StudioCoreApi.CreateHistory(state));

    public void Commit(byte[] state)
    {
        ThrowIfDisposed();
        StudioCoreApi.Commit(_handle, state);
    }

    public byte[]? Undo(byte[] current)
    {
        ThrowIfDisposed();
        return StudioCoreApi.Undo(_handle, current);
    }

    public byte[]? Redo(byte[] current)
    {
        ThrowIfDisposed();
        return StudioCoreApi.Redo(_handle, current);
    }

    public (bool CanUndo, bool CanRedo) Flags(byte[] current)
    {
        ThrowIfDisposed();
        return StudioCoreApi.Flags(_handle, current);
    }

    public void MarkClean(byte[] state)
    {
        ThrowIfDisposed();
        StudioCoreApi.MarkClean(_handle, state);
    }

    public bool IsDirty(byte[] current)
    {
        ThrowIfDisposed();
        return StudioCoreApi.IsDirty(_handle, current);
    }

    public void Dispose()
    {
        if (_handle == IntPtr.Zero)
        {
            return;
        }
        StudioCoreApi.DestroyHistory(_handle);
        _handle = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_handle == IntPtr.Zero, this);
    }
}
