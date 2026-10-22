<# : batch
@echo off
setlocal
set "VPN_SCRIPT=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:VPN_SCRIPT, [Text.Encoding]::UTF8))"
echo.
pause
exit /b
#>
# Część PowerShell - plik jest jednocześnie .bat (uruchamia sam siebie przez PowerShell) i skryptem PowerShell.
<#
.SYNOPSIS
    Interaktywnie tworzy lub modyfikuje połączenie VPN (wbudowany klient VPN Windows),
    opcjonalnie włącza split tunneling i ustawia metrykę interfejsu, a na koniec testuje połączenie.

.DESCRIPTION
    Po co to jest:
    Przy split tunnelingu ruch do internetu idzie przez lokalne łącze, ale Windows wybiera serwery DNS
    według metryki interfejsu. VPN domyślnie dostaje metrykę automatyczną (zwykle 25), niższą niż Wi-Fi (35),
    więc zapytania DNS trafiają najpierw do serwerów DNS klienta przez tunel. Jeśli te serwery są wolne
    lub nie odpowiadają, strony ładują się z kilkunastosekundowym opóźnieniem albo wcale,
    mimo że sprawdzenie IP pokazuje lokalny adres.

    Przebieg:
      1. wybór VPN z listy (ostatnia pozycja = nowe połączenie); połączenie jest edytowane w miejscu,
         bo usunięcie skasowałoby zapisane w Windows hasło i klucz wstępny (nie da się ich odczytać),
      2. kolejno: nazwa, serwer, typ, klucz wstępny, login (domyślnie obecny / ostatni dla serwera),
         hasło - pusty Enter pomija krok,
      3. (opcjonalnie) split tunneling + metryka IpInterfaceMetric / Ipv6InterfaceMetric w rasphone.pbk,
         wyższa niż lokalnych kart, dzięki czemu lokalny DNS ma pierwszeństwo,
      4. test: zestawienie połączenia, trasa do internetu poza tunelem, kolejność i czas DNS.

    Set-VpnConnection nie obsługuje metryki, dlatego jest ona zmieniana bezpośrednio w pliku rasphone.pbk
    (to samo co: ncpa.cpl -> VPN -> Właściwości -> Sieć -> IPv4/IPv6 -> Zaawansowane -> Metryka automatyczna).
    Plik jest zapisywany w oryginalnym kodowaniu - zmiana kodowania psuje zestawianie połączeń.
    Przed zmianą tworzona jest kopia zapasowa. Nie wymaga uprawnień administratora (połączenia użytkownika).
#>

# Automatyczne metryki kart to zwykle 25-55 (Wi-Fi bywa 35 albo 50), więc 100 jest zawsze wyżej
$Metric = 100
$pbk = "$env:APPDATA\Microsoft\Network\Connections\Pbk\rasphone.pbk"

Write-Host @"
==============================================================================
 Konfiguracja VPN (wbudowany klient VPN Windows)
==============================================================================
 Tworzy nowe albo zmienia istniejące połączenie VPN, a potem:
  - włącza split tunneling: przez VPN idzie tylko ruch do sieci firmy,
    internet idzie przez Twoje łącze,
  - ustawia VPN niższy priorytet DNS niż karta sieciowa - bez tego wolne
    lub niedziałające DNS-y po drugiej stronie tunelu potrafią spowolnić
    ładowanie wszystkich stron o kilkanaście sekund,
  - na koniec testuje połączenie, trasy i DNS.

 Hasła i klucze trafiają tylko do połączenia VPN w Windows - skrypt
 nigdzie ich nie zapisuje. Uprawnienia administratora nie są potrzebne.

 Enter = wartość domyślna / bez zmian      Esc = przerwij
==============================================================================
"@ -ForegroundColor Cyan

Add-Type -Namespace Ras -Name Api -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RASCREDENTIALS {
    public int dwSize;
    public int dwMask;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szUserName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szPassword;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)]  public string szDomain;
}
public const int RASCM_UserName = 1, RASCM_Password = 2, RASCM_PreSharedKey = 0x10;
[DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
public static extern int RasGetCredentials(string lpszPhonebook, string lpszEntry, ref RASCREDENTIALS c);
[DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
public static extern int RasSetCredentials(string lpszPhonebook, string lpszEntry, ref RASCREDENTIALS c, bool fClearCredentials);
[DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
public static extern int RasRenameEntry(string lpszPhonebook, string lpszOldEntry, string lpszNewEntry);
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RASDIALPARAMS {
    public int dwSize;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szEntryName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szPhoneNumber;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)] public string szCallbackNumber;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szUserName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szPassword;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)]  public string szDomain;
    public int dwSubEntry;
    public IntPtr dwCallbackId;
    public int dwIfIndex;
}
[DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
public static extern int RasGetEntryDialParams(string lpszPhonebook, ref RASDIALPARAMS p, out bool fPassword);
[DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
public static extern int RasDial(IntPtr ext, string lpszPhonebook, ref RASDIALPARAMS p, int notifierType, IntPtr notifier, out IntPtr hConn);
[DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
public static extern int RasHangUp(IntPtr hConn);
[DllImport("rasapi32.dll", CharSet = CharSet.Unicode)]
public static extern int RasGetErrorString(int err, System.Text.StringBuilder buf, int size);
'@

# Etykiety jak w Ustawienia -> Sieć i Internet -> VPN -> Dodaj VPN -> Typ sieci VPN
$Types = @(
    @{ Label = 'Automatyczny';                                     Tunnel = 'Automatic'; Psk = $false }
    @{ Label = 'Protokół PPTP (Point to Point Tunneling Protocol)'; Tunnel = 'Pptp';      Psk = $false }
    @{ Label = 'Protokół L2TP/IPsec z certyfikatem';                Tunnel = 'L2tp';      Psk = $false }
    @{ Label = 'Protokół L2TP/IPsec z kluczem wstępnym';            Tunnel = 'L2tp';      Psk = $true  }
    @{ Label = 'Protokół SSTP (Secure Socket Tunneling Protocol)';  Tunnel = 'Sstp';      Psk = $false }
    @{ Label = 'IKEv2';                                             Tunnel = 'Ikev2';     Psk = $false }
)

# Wczytanie linii znak po znaku - Read-Line nie pozwala przerwać klawiszem Esc
function Read-Line([string]$Prompt, [switch]$Mask) {
    Write-Host "$($Prompt): " -NoNewline
    $sb = [Text.StringBuilder]::new()
    while ($true) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'Enter'     { Write-Host; return $sb.ToString() }
            'Escape'    { Stop-Script }
            'Backspace' { if ($sb.Length) { [void]$sb.Remove($sb.Length - 1, 1); Write-Host "`b `b" -NoNewline } }
            default {
                if (-not [char]::IsControl($k.KeyChar)) {
                    [void]$sb.Append($k.KeyChar)
                    Write-Host $(if ($Mask) { '*' } else { $k.KeyChar }) -NoNewline
                }
            }
        }
    }
}

function Stop-Script {
    Write-Host "`n`nPrzerwano (Esc). Zmiany zapisane przed przerwaniem zostają." -ForegroundColor Yellow
    exit 2
}

function Read-Choice([string]$Title, [string[]]$Options, [string]$SkipText) {
    Write-Host "`n$Title"
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $Options[$i]) }
    while ($true) {
        $a = Read-Line $(if ($SkipText) { "Numer (Enter = $SkipText)" } else { 'Numer' })
        if (-not $a -and $SkipText) { return $null }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n - 1 }
        Write-Host 'Niepoprawny numer.' -ForegroundColor Yellow
    }
}

function Read-Secret([string]$Prompt) {
    Read-Line $Prompt -Mask
}

function Read-YesNo([string]$Prompt) {
    while ($true) {
        $a = (Read-Line "$Prompt [T/n] (Enter = tak)").Trim().ToLower()
        if ($a -in '', 't', 'tak', 'y') { return $true }
        if ($a -in 'n', 'nie') { return $false }
    }
}

# --- rasphone.pbk: zachowanie oryginalnego kodowania ---
function Get-PbkEncoding {
    $b = [IO.File]::ReadAllBytes($pbk)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return [Text.UTF8Encoding]::new($true) }
    [Text.Encoding]::Default
}

function Get-PbkValue([string]$Entry, [string]$Key) {
    $section = $null
    foreach ($l in [IO.File]::ReadAllLines($pbk, (Get-PbkEncoding))) {
        if ($l -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        if ($section -eq $Entry -and $l -match "^$Key=(.*)$") { return $Matches[1] }
    }
}

# $Values: hashtable klucz -> wartość; zwraca liczbę zmienionych linii
function Set-PbkValues([string]$Entry, [hashtable]$Values) {
    $enc = Get-PbkEncoding
    $lines = [IO.File]::ReadAllText($pbk, $enc) -split "`r`n"
    $section = $null
    $changed = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        if ($section -eq $Entry -and $lines[$i] -match '^([^=]+)=' -and $Values.ContainsKey($Matches[1])) {
            $lines[$i] = "$($Matches[1])=$($Values[$Matches[1]])"
            $changed++
        }
    }
    [IO.File]::WriteAllText($pbk, ($lines -join "`r`n"), $enc)
    $changed
}

function Get-SavedLogin([string]$Entry) {
    $c = New-Object Ras.Api+RASCREDENTIALS
    $c.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($c)
    $c.dwMask = [Ras.Api]::RASCM_UserName
    if ([Ras.Api]::RasGetCredentials($pbk, $Entry, [ref]$c) -eq 0) { $c.szUserName }
}

function Get-TypeIndex($Conn) {
    if ($Conn.TunnelType -eq 'L2tp') {
        $c = New-Object Ras.Api+RASCREDENTIALS
        $c.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($c)
        $c.dwMask = [Ras.Api]::RASCM_PreSharedKey
        $hasPsk = [Ras.Api]::RasGetCredentials($pbk, $Conn.Name, [ref]$c) -eq 0 -and ($c.dwMask -band [Ras.Api]::RASCM_PreSharedKey)
        if ($hasPsk -or (Get-PbkValue $Conn.Name 'IpSecFlags') -eq '1') { return 3 } else { return 2 }
    }
    for ($i = 0; $i -lt $Types.Count; $i++) { if ($Types[$i].Tunnel -eq "$($Conn.TunnelType)") { return $i } }
}

if (Test-Path $pbk) { Copy-Item $pbk "$pbk.$(Get-Date -f yyyyMMdd-HHmmss).bak" }

# --- 1. wybór połączenia ---
$vpns = @(Get-VpnConnection | Sort-Object Name)
$labels = @($vpns | ForEach-Object { "{0}  ({1}, {2}, {3})" -f $_.Name, $Types[(Get-TypeIndex $_)].Label, $_.ServerAddress, $_.ConnectionStatus }) + 'Nowe połączenie'
$idx = Read-Choice 'Połączenia VPN:' $labels 'nowe połączenie'
if ($null -eq $idx) { $idx = $vpns.Count }
$isNew = $idx -eq $vpns.Count
$conn = if (-not $isNew) { $vpns[$idx] }

if ($conn -and $conn.ConnectionStatus -eq 'Connected') {
    throw "Połączenie '$($conn.Name)' jest aktywne. Rozłącz je i uruchom skrypt ponownie."
}

# --- 2. nazwa i serwer ---
# Połączenie jest edytowane w miejscu - usunięcie skasowałoby zapisane hasło i klucz wstępny
if ($isNew) {
    do { $name = (Read-Line "`nNazwa").Trim() } while (-not $name)
    if (Get-VpnConnection -Name $name -ErrorAction SilentlyContinue) { throw "Połączenie '$name' już istnieje." }
    do { $server = (Read-Line 'Adres serwera').Trim() } while (-not $server)
} else {
    $name = $conn.Name
    $newName = (Read-Line "`nNazwa [$name] (Enter = bez zmian)").Trim()
    if ($newName -and $newName -ne $name) {
        $r = [Ras.Api]::RasRenameEntry($pbk, $name, $newName)
        if ($r -ne 0) { throw "Nie udało się zmienić nazwy (błąd RAS $r)." }
        "Zmieniono nazwę: $name -> $newName"
        $name = $newName
    }
    $server = (Read-Line "Adres serwera [$($conn.ServerAddress)] (Enter = bez zmian)").Trim()
    if ($server -and $server -ne $conn.ServerAddress) {
        Set-VpnConnection -Name $name -ServerAddress $server -Force
        "Zmieniono serwer."
    } else {
        $server = $conn.ServerAddress
    }
}

# --- 3. typ ---
$curType = if ($conn) { Get-TypeIndex $conn }
if ($isNew) {
    $t = Read-Choice 'Typ sieci VPN:' $Types.Label 'Automatyczny'
    if ($null -eq $t) { $t = 0 }
} else {
    $t = Read-Choice "Typ sieci VPN (obecnie: $($Types[$curType].Label)):" $Types.Label 'bez zmian'
    if ($null -eq $t) { $t = $curType }
}
$type = $Types[$t]

# --- 4. klucz wstępny ---
# Hasła i klucze nie są nigdzie przechowywane poza połączeniem VPN (Windows nie pozwala ich odczytać)
$psk = $null
if ($type.Psk) {
    # wymagany, gdy połączenie dopiero dostaje typ z kluczem wstępnym
    $required = $isNew -or $curType -ne 3
    do {
        $psk = Read-Secret $(if ($required) { "`nKlucz wstępny" } else { "`nKlucz wstępny [zapisany] (Enter = bez zmian)" })
    } while ($required -and -not $psk)
}

if ($isNew) {
    $p = @{ Name = $name; ServerAddress = $server; TunnelType = $type.Tunnel; AuthenticationMethod = 'MSChapv2'; RememberCredential = $true; Force = $true }
    if ($psk) { $p.L2tpPsk = $psk }
    Add-VpnConnection @p
    "Utworzono połączenie '$name'."
} elseif ($t -ne $curType -or $psk) {
    $p = @{ Name = $name; TunnelType = $type.Tunnel; Force = $true }
    if ($psk) { $p.L2tpPsk = $psk }
    Set-VpnConnection @p
    if ($type.Tunnel -eq 'L2tp' -and -not $type.Psk) { [void](Set-PbkValues $name @{ IpSecFlags = '0' }) }
    "Zaktualizowano typ / klucz wstępny."
}

# --- 5. login i hasło ---
$rasUser = $null
$hasPwd = $false
if ($isNew) {
    # domyślnie login z ostatnio dodanego połączenia do tego samego serwera
    $curUser = Get-VpnConnection | Where-Object { $_.ServerAddress -eq $server -and $_.Name -ne $name } |
        ForEach-Object { Get-SavedLogin $_.Name } | Where-Object { $_ } | Select-Object -Last 1
} else {
    $cred = New-Object Ras.Api+RASCREDENTIALS
    $cred.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($cred)
    $cred.dwMask = [Ras.Api]::RASCM_UserName -bor [Ras.Api]::RASCM_Password
    [void][Ras.Api]::RasGetCredentials($pbk, $name, [ref]$cred)
    $curUser = $rasUser = $cred.szUserName
    $hasPwd = ($cred.dwMask -band [Ras.Api]::RASCM_Password) -ne 0
}

$skip = if ($isNew) { 'pomiń' } else { 'bez zmian' }
$login = if ($curUser) {
    $l = (Read-Line "`nLogin [$curUser] (Enter = $curUser)").Trim()
    if ($l) { $l } else { $curUser }
} else {
    (Read-Line "`nLogin (Enter = $skip)").Trim()
}
$password = Read-Secret "Hasło$(if ($hasPwd) { ' [zapisane]' }) (Enter = $skip)"

if (($login -and $login -ne $rasUser) -or $password) {
    # Zapis przez RasSetCredentials - z tego magazynu korzysta okno VPN w Windows
    $new = New-Object Ras.Api+RASCREDENTIALS
    $new.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($new)
    if ($login) { $new.szUserName = $login; $new.dwMask = [Ras.Api]::RASCM_UserName }
    if ($password) { $new.szPassword = $password; $new.dwMask = $new.dwMask -bor [Ras.Api]::RASCM_Password }
    $r = [Ras.Api]::RasSetCredentials($pbk, $name, [ref]$new, $false)
    if ($r -ne 0) { throw "Nie udało się zapisać loginu/hasła (błąd RAS $r)." }
    "Zapisano dane logowania."
}

# --- 6. split tunneling i metryka ---
Write-Host @"

Split tunneling + metryka $($Metric):
  przez VPN idzie tylko ruch do sieci firmy, internet przez lokalne łącze, a DNS jest pytany
  najpierw lokalnie - inaczej wolne/martwe DNS-y firmy spowalniają ładowanie wszystkich stron.
"@
$doSplit = Read-YesNo 'Ustawić?'
if ($doSplit) {
    Set-VpnConnection -Name $name -SplitTunneling $true -Force
    $n = Set-PbkValues $name @{ IpInterfaceMetric = "$Metric"; Ipv6InterfaceMetric = "$Metric" }
    "Włączono split tunneling, metryka $Metric ($n wpisy)."
}

Get-VpnConnection -Name $name | Format-List Name, ServerAddress, TunnelType, SplitTunneling

# --- 7. test ---
if (-not (Read-YesNo 'Przetestować połączenie?')) { return }

function Write-Result([bool]$Ok, [string]$Text) {
    if ($Ok) { Write-Host "  [OK]   $Text" -ForegroundColor Green } else { Write-Host "  [BŁĄD] $Text" -ForegroundColor Red }
}

Write-Host "`nŁączenie z $name..."
# Windows nie zestawi drugiego tunelu do tego samego serwera (błąd 633)
$busy = @(Get-VpnConnection | Where-Object { $_.Name -ne $name -and $_.ServerAddress -eq $server -and $_.ConnectionStatus -eq 'Connected' })
foreach ($b in $busy) {
    Write-Host "Połączenie '$($b.Name)' do tego samego serwera jest aktywne - Windows nie zestawi drugiego tunelu." -ForegroundColor Yellow
    if (-not (Read-YesNo "Rozłączyć '$($b.Name)'?")) { Write-Host 'Pominięto test.'; return }
    $null = rasdial.exe $b.Name /disconnect
    # odczekanie na pełne rozłączenie, zanim zestawimy nowy tunel do tego samego serwera
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-VpnConnection -Name $b.Name).ConnectionStatus -ne 'Disconnected' -and (Get-Date) -lt $deadline) { Start-Sleep 1 }
    Start-Sleep 2
}
# rasdial.exe z zapisanymi danymi kończy się błędem 628, a wywołanie RasDial z tymi samymi danymi działa
$dp = New-Object Ras.Api+RASDIALPARAMS
$dp.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($dp)
$dp.szEntryName = $name
$hasSaved = $false
[void][Ras.Api]::RasGetEntryDialParams($pbk, [ref]$dp, [ref]$hasSaved)
if ($login) { $dp.szUserName = $login }
if ($password) { $dp.szPassword = $password }
$hConn = [IntPtr]::Zero
$r = [Ras.Api]::RasDial([IntPtr]::Zero, $pbk, [ref]$dp, 0, [IntPtr]::Zero, [ref]$hConn)
$status = (Get-VpnConnection -Name $name).ConnectionStatus
if ($r -ne 0) {
    if ($hConn -ne [IntPtr]::Zero) { [void][Ras.Api]::RasHangUp($hConn) }
    $msg = [Text.StringBuilder]::new(512)
    [void][Ras.Api]::RasGetErrorString($r, $msg, $msg.Capacity)
    Write-Host "Błąd $($r): $msg" -ForegroundColor Yellow
}
if ($status -ne 'Connected') {
    Write-Host "Nie udało się połączyć automatycznie. Otwieram Ustawienia VPN - kliknij 'Połącz' przy '$name'. Czekam do 2 minut..."
    Start-Process 'ms-settings:network-vpn'
    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep 2
        while ([Console]::KeyAvailable) { if ([Console]::ReadKey($true).Key -eq 'Escape') { Stop-Script } }
        $status = (Get-VpnConnection -Name $name).ConnectionStatus
    } while ($status -ne 'Connected' -and (Get-Date) -lt $deadline)
}

Write-Host "`nWyniki testu:"
Write-Result ($status -eq 'Connected') "Połączenie: $status"
if ($status -ne 'Connected') { return }

$vpnIf = Get-NetIPInterface -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue
$vpnIp = (Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
Write-Result ([bool]$vpnIp) "Adres w tunelu: $vpnIp"

$vpnRoutes = Get-NetRoute -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -notmatch '^(255\.|224\.)' -and $_.DestinationPrefix -ne "$vpnIp/32" } |
    Select-Object -ExpandProperty DestinationPrefix -Unique
Write-Host "         Trasy przez tunel: $($vpnRoutes -join ', ')"

# split tunneling: internet nie może iść przez VPN
$inet = Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction SilentlyContinue | Select-Object -First 1
$hwAlias = $inet.InterfaceAlias
Write-Result ($hwAlias -and $hwAlias -ne $name) "Internet (1.1.1.1) idzie przez: $hwAlias"
Write-Result ('0.0.0.0/0' -notin $vpnRoutes) 'Brak trasy domyślnej przez tunel'

# DNS: karta sprzętowa musi mieć niższą metrykę niż VPN, bo jej serwery są pytane jako pierwsze
$hwIf = Get-NetIPInterface -InterfaceAlias $hwAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue
$hwDns = (Get-DnsClientServerAddress -InterfaceAlias $hwAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
$vpnDns = (Get-DnsClientServerAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
Write-Result ($hwIf.InterfaceMetric -lt $vpnIf.InterfaceMetric) "Metryka: $hwAlias = $($hwIf.InterfaceMetric), $name = $($vpnIf.InterfaceMetric)"
Write-Host "         DNS $($hwAlias): $($hwDns -join ', ')"
Write-Host "         DNS $($name): $($vpnDns -join ', ')"

$withDns = (Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses }).InterfaceIndex
$first = Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected |
    Where-Object { $_.InterfaceIndex -in $withDns } |
    Sort-Object InterfaceMetric | Select-Object -First 1
Write-Result ($first.InterfaceAlias -ne $name) "DNS pytany jako pierwszy: $($first.InterfaceAlias)"

# czas rozwiązywania nazw (bez cache, losowa subdomena wymusza zapytanie do serwera)
foreach ($host_ in 'www.google.com', "test$(Get-Random).example.com") {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Resolve-DnsName $host_ -DnsOnly -NoHostsFile -ErrorAction SilentlyContinue
    $sw.Stop()
    $ms = [int]$sw.ElapsedMilliseconds
    Write-Result ($ms -lt 1000) "DNS $host_ : $ms ms"
}

Write-Host "`nPołączenie zostaje aktywne."
