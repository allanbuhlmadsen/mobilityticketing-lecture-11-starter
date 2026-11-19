using System.Security.Cryptography;

namespace MobilityTicketing.Reports.Application;

public sealed class ReportWorkflow(
    IReportObjectStore storage, IReportCatalogue catalogue, IUploadReceipts receipts, ExportLocation destination)
{
    private readonly IReportObjectStore _storage = storage;
    private readonly IReportCatalogue _catalogue = catalogue;
    private readonly IUploadReceipts _receipts = receipts;
    private readonly ExportLocation _destination = destination;

    public async Task<string> StageAsync(string reportId, byte[] bytes)
    {
        // Both measurements are taken from the same array that is uploaded, so the
        // receipt describes exactly the bytes that were sent and not a second reading
        // of the file.
        var (sha256, rowCount) = Measure(bytes);

        // Reserving before the PUT is what stops a second attempt for the same report
        // ID from starting while the outcome of the first one is still unknown. The
        // receipt adapter refuses an existing reservation.
        _receipts.Reserve(reportId);

        var versionId = await _storage.UploadAsync(_destination, bytes);
        if (string.IsNullOrWhiteSpace(versionId) || versionId is "null" or "None")
            throw new InvalidOperationException(
                $"The upload of {reportId} returned no usable version ID, so the exact bytes cannot be read back later.");

        var staged = new ReportInput(
            reportId, _destination.Bucket, _destination.Key, versionId, sha256, rowCount);
        await _receipts.WriteAsync(staged);
        return versionId;
    }

    public async Task<string> PublishAsync(string reportId, byte[] bytes, string? supersedes)
    {
        // Publishing is staging followed by recovery. Splitting it this way is what
        // lets the separate stage command stop halfway and lets recovery finish the
        // job later without a second PUT.
        await StageAsync(reportId, bytes);
        return await RecoverAsync(reportId, supersedes);
    }

    public async Task<string> RecoverAsync(string reportId, string? supersedes)
    {
        // The receipt carries the version that was uploaded, so recovery reads that
        // exact version instead of uploading anything again. Repeating a recovery
        // therefore issues no PUT and creates no further object version.
        var staged = await _receipts.ReadAsync(reportId);

        var result = await CheckAsync(staged);
        if (result != Verification.Matches)
            throw new InvalidOperationException(
                $"Recovery of {reportId} stopped because verifying the staged version returned {result}. Nothing was written to the catalogue.");

        await _catalogue.SaveAsync(staged, supersedes);
        return $"Saved {reportId}";
    }

    public async Task<Verification> VerifyAsync(string reportId)
    {
        // The catalogue is what turns a report ID into a bucket, a key and one exact
        // version. A failure to read it is not the same as a report that is not there,
        // so the two get different results and different exit codes.
        ReportInput? stored;
        try
        {
            stored = await _catalogue.FindAsync(reportId);
        }
        catch (CatalogueException)
        {
            return Verification.CatalogueReadFailed;
        }

        return stored is null ? Verification.UnknownReport : await CheckAsync(stored);
    }

    private async Task<Verification> CheckAsync(ReportInput input)
    {
        // The location comes from the stored record and not from _destination, so a
        // report that was written to a different key is still read from the key it
        // actually went to.
        byte[] bytes;
        try
        {
            bytes = await _storage.ReadVersionAsync(
                new ExportLocation(input.Bucket, input.Key), input.VersionId);
        }
        catch (ObjectStoreException)
        {
            // A read that did not complete says nothing about the bytes. It is reported
            // as its own result rather than as a mismatch.
            return Verification.ReadFailed;
        }

        var (sha256, rowCount) = Measure(bytes);
        return sha256 == input.Sha256 && rowCount == input.RowCount
            ? Verification.Matches
            : Verification.Mismatch;
    }

    // One measurement used by both the upload and the verification, so the two cannot
    // drift apart.
    private static (string Sha256, int RowCount) Measure(byte[] bytes) =>
        (Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(),
            bytes.Count(b => b == (byte)'\n'));
}