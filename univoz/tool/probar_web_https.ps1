param(
  [int]$Port = 8731,
  [string]$HostAddress = ''
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
  throw 'Falta openssl. Instala OpenSSL o mkcert y vuelve a ejecutar este script.'
}

if (-not $HostAddress) {
  $HostAddress = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*' -and
      $_.PrefixOrigin -ne 'WellKnown'
    } |
    Select-Object -First 1 -ExpandProperty IPAddress
}

if (-not $HostAddress) {
  throw 'No encontré IPv4 de red. Pasa -HostAddress con la IP de la PC.'
}

$certDir = Join-Path (Get-Location) '.dev-certs'
$certPath = Join-Path $certDir 'univoz-cert.pem'
$keyPath = Join-Path $certDir 'univoz-key.pem'
New-Item -ItemType Directory -Force $certDir | Out-Null

if (-not (Test-Path $certPath) -or -not (Test-Path $keyPath)) {
  & openssl req -x509 -newkey rsa:2048 -nodes `
    -keyout $keyPath -out $certPath -days 365 `
    -subj "/CN=$HostAddress" -addext "subjectAltName=IP:$HostAddress"
  if ($LASTEXITCODE -ne 0) {
    throw 'OpenSSL no pudo crear certificado HTTPS.'
  }
}

flutter build web --release

$url = "https://$HostAddress`:$Port/"
Write-Host "Abre en teléfono: $url"
Write-Host 'El navegador puede mostrar aviso por certificado local; entra en Avanzado > Continuar.'
Write-Host 'La primera vez, concede permiso de cámara.'

if (Get-Command npx -ErrorAction SilentlyContinue) {
  & npx --yes -p qrcode-terminal node -e "require('qrcode-terminal').generate('$url', {small:true})"
}

flutter run -d web-server --release `
  --web-hostname 0.0.0.0 `
  --web-port $Port `
  --web-tls-cert-path $certPath `
  --web-tls-cert-key-path $keyPath `
  --web-launch-url $url
