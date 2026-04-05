function Broadcast-WebSocketData {
    param([object]$Data)
    if ($script:WSClients.Count -eq 0) { return }
    $json = $null
    try { $json = $Data | ConvertTo-Json -Compress -Depth 20 } catch { return }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $buffer = [byte[]]::new(4096)
    foreach ($ws in @($script:WSClients)) {
        try {
            if ($ws.State -eq 'Open') {
                $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [System.Threading.CancellationToken]::None)
            }
        } catch {}
    }
}

function Send-Response($response, $data, $type = "application/json", $contentDisposition = $null) {
    try {
        if ($null -ne $contentDisposition -and $contentDisposition -ne "") {
            $response.Headers.Add("Content-Disposition", $contentDisposition)
        }
        if ($null -ne $data) {
            if ($data -is [byte[]]) {
                $response.ContentType = $type
                $response.ContentLength64 = $data.Length
                $response.OutputStream.Write($data, 0, $data.Length)
            } else {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($data)
                $response.ContentType = $type
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
        }
    } catch {}
    try { $response.Close() } catch {}
}
