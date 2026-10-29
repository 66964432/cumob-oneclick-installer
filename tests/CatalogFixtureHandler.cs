using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

// In-memory transport. The installer still exercises HttpClient, streaming and validation.
public class CumobCatalogFixtureHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        var url = request.RequestUri;
        var key = Environment.GetEnvironmentVariable("CUMOB_TEST_EXPECTED_KEY");
        var version = Environment.GetEnvironmentVariable("CUMOB_CODEX_CLIENT_VERSION");
        if (url.Scheme != "https" || (url.Host != "api.cumob.com" && url.Host != "api.cumob.cn") ||
            url.AbsolutePath != "/v1/codex/models" || url.Query != "?client_version=" + version ||
            request.Headers.Authorization == null || request.Headers.Authorization.ToString() != "Bearer " + key)
            throw new InvalidOperationException("Incorrect test catalog request");
        var log = Environment.GetEnvironmentVariable("CUMOB_TEST_REQUESTS");
        if (!String.IsNullOrEmpty(log)) File.AppendAllText(log, url.ToString() + Environment.NewLine);
        var mode = Environment.GetEnvironmentVariable("CUMOB_TEST_MODE");
        if (mode == "timeout") throw new TaskCanceledException("Simulated timeout");
        var status = mode == "401" ? HttpStatusCode.Unauthorized :
            mode == "redirect" ? HttpStatusCode.Redirect : HttpStatusCode.OK;
        byte[] data;
        if (mode == "oversize") data = new byte[1048577];
        else if (mode == "invalid-json") data = System.Text.Encoding.UTF8.GetBytes("not JSON");
        else data = File.ReadAllBytes(Environment.GetEnvironmentVariable("CUMOB_TEST_CATALOG"));
        var response = new HttpResponseMessage(status) { Content = new ByteArrayContent(data) };
        if (mode == "redirect") response.Headers.Location = new Uri("https://untrusted.invalid/");
        return Task.FromResult(response);
    }
}
