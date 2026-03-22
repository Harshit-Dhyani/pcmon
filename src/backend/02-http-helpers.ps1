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
