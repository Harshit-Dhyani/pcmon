function Broadcast-WebSocketData {
    param([object]$Data)
    if ($script:WSClients.Count -eq 0) { return }
    $json = $null
    try { $json = $Data | ConvertTo-Json -Compress -Depth 20 } catch { Write-Log "WebSocket serialization failed: $($_.Exception.Message)" "DEBUG"; return }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    foreach ($ws in @($script:WSClients)) {
        try {
            if ($ws.State -eq 'Open') {
                $null = $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [System.Threading.CancellationToken]::None)
            }
        } catch {
            Write-Log "WebSocket send failed: $($_.Exception.Message)" "DEBUG"
        }
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
    } catch {
        Write-Log "HTTP response write failed: $($_.Exception.Message)" "DEBUG"
    }
    try { $response.Close() } catch { Write-Log "HTTP response close failed: $($_.Exception.Message)" "DEBUG" }
}

function Send-JsonObject($response, $obj, [int]$StatusCode = 200) {
    $response.StatusCode = $StatusCode
    $json = $obj | ConvertTo-Json -Depth 20 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-Response $response $buffer "application/json"
}

function Send-JsonError($response, [int]$StatusCode, [string]$Message) {
    Send-JsonObject $response @{ success = $false; error = $Message; status = $StatusCode } $StatusCode
}

function ConvertTo-HtmlEscaped {
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}
