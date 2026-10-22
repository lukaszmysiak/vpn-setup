# vpn-setup

Interaktywny skrypt do tworzenia i zmiany połączeń VPN we wbudowanym kliencie VPN Windows. Włącza split tunneling, ustawia priorytet DNS i na koniec testuje połączenie.

Całość to jeden plik `vpn-setup.bat`, który w środku zawiera skrypt PowerShell. Wystarczy go rozesłać i uruchomić dwuklikiem.

## Po co

Przy split tunnelingu ruch do internetu idzie przez lokalne łącze, a przez VPN tylko ruch do sieci firmy. Windows wybiera jednak serwery DNS według metryki interfejsu. VPN dostaje domyślnie metrykę automatyczną (zwykle 25), niższą niż Wi-Fi (35–50), więc **każde** zapytanie DNS idzie najpierw do serwerów DNS po drugiej stronie tunelu.

Jeśli te serwery są wolne albo nie odpowiadają, wszystkie strony ładują się z kilkunastosekundowym opóźnieniem albo wcale. Sprawdzenie IP pokazuje przy tym lokalny adres, więc trudno skojarzyć problem z VPN-em.

Skrypt ustawia VPN-owi metrykę 100. Dzięki temu najpierw pytany jest DNS z lokalnej karty, a przez tunel idzie tylko ruch do podsieci firmy.

## Wymagania

- Windows 10 lub 11 z Windows PowerShell 5.1 (jest w systemie).
- Uprawnienia administratora **nie są potrzebne**. Skrypt działa na połączeniach VPN bieżącego użytkownika.
- Prawdziwe okno konsoli. Skrypt wczytuje klawisze bezpośrednio, więc nie zadziała przez SSH, zdalną sesję PowerShell ani z przekierowanym wejściem.

## Użycie

Uruchom `vpn-setup.bat` dwuklikiem.

- **Enter** – wartość domyślna albo bez zmian.
- **Esc** – przerwanie w dowolnym momencie. Zmiany zapisane przed przerwaniem zostają.

Kolejne kroki:

1. **Wybór połączenia** z listy VPN-ów na komputerze. Enter = nowe połączenie.
2. **Nazwa** i **adres serwera**.
3. **Typ sieci VPN** – te same opcje co w Ustawienia → Sieć i Internet → VPN:
   Automatyczny, PPTP, L2TP/IPsec z certyfikatem, L2TP/IPsec z kluczem wstępnym, SSTP, IKEv2.
4. **Klucz wstępny** – tylko dla L2TP/IPsec z kluczem wstępnym.
5. **Login** i **hasło**. Przy nowym połączeniu podpowiadany jest login z innego połączenia do tego samego serwera.
6. **Split tunneling i metryka** – pytanie T/n z krótkim opisem.
7. **Test** (opcjonalny):
   - zestawienie połączenia,
   - adres w tunelu i trasy przez tunel,
   - czy internet idzie przez lokalną kartę, a nie przez VPN,
   - czy lokalny DNS jest pytany jako pierwszy,
   - czas odpowiedzi DNS.

   Po teście połączenie zostaje aktywne.

### Edycja istniejącego połączenia

Połączenie jest zmieniane w miejscu, a nie usuwane i tworzone od nowa. Windows nie pozwala odczytać zapisanego hasła ani klucza wstępnego, więc usunięcie połączenia skasowałoby je bezpowrotnie. Enter przy haśle i kluczu zostawia zapisane wartości.

Aktywnego połączenia nie da się edytować – trzeba je najpierw rozłączyć.

## Co skrypt zmienia w systemie

- **Profil VPN** bieżącego użytkownika: tworzenie, zmiana nazwy, serwera, typu, klucza, split tunnelingu.
- **Metrykę interfejsu** (`IpInterfaceMetric`, `Ipv6InterfaceMetric`) w pliku
  `%APPDATA%\Microsoft\Network\Connections\Pbk\rasphone.pbk`.
  `Set-VpnConnection` nie obsługuje metryki, więc jest ona zmieniana bezpośrednio w pliku, z zachowaniem jego kodowania.
- **Kopię zapasową** `rasphone.pbk` przy każdym uruchomieniu, w tym samym folderze (`rasphone.pbk.RRRRMMDD-GGMMSS.bak`). Kopie zawierają nazwy połączeń i adresy serwerów, bez haseł i kluczy. Możesz je usuwać.
- **Dane logowania** wybranego połączenia w magazynie Windows – tym samym, z którego korzysta okno VPN w Ustawieniach.
- **Rozłączenie** innego aktywnego połączenia do tego samego serwera podczas testu, bo Windows nie zestawi dwóch tuneli do jednego serwera. Skrypt zawsze pyta wcześniej.

## Bezpieczeństwo

- Hasła i klucze trafiają **tylko** do połączenia VPN w Windows. Skrypt nigdzie ich nie zapisuje i nie odczytuje haseł innych połączeń (Windows i tak zwraca je jako `****************`).
- Hasło nie pojawia się w wierszu poleceń żadnego procesu – łączenie odbywa się przez funkcję Windows `RasDial`, a nie `rasdial.exe` z hasłem w argumentach.
- Skrypt niczego nie pobiera z internetu i nic nie wysyła. Jedyny ruch sieciowy to połączenie z Twoim serwerem VPN oraz dwa zapytania DNS w teście.
- `-ExecutionPolicy Bypass` dotyczy tylko tego jednego uruchomienia PowerShella i nie zmienia ustawień systemu.

### Antywirus

Połączenie `ExecutionPolicy Bypass`, uruchamiania własnej treści i wywołań API Windows (`Add-Type` z P/Invoke) bywa oznaczane przez heurystyki antywirusów jako podejrzane. Jeśli plik zostanie zablokowany, przejrzyj go (to zwykły tekst) i dodaj wyjątek.

## Jak to działa technicznie

Plik jest jednocześnie skryptem wsadowym i skryptem PowerShell:

```bat
<# : batch
@echo off
...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:VPN_SCRIPT, [Text.Encoding]::UTF8))"
...
exit /b
#>
```

`cmd` wykonuje nagłówek i kończy na `exit /b`. PowerShell traktuje ten sam nagłówek jako komentarz blokowy `<# … #>` i wykonuje resztę pliku. Plik jest zapisany jako UTF-8 bez BOM – BOM zepsułby pierwszą linię dla `cmd`.

## Znane ograniczenia

- `rasdial.exe` bez podanego hasła kończy się dla części połączeń L2TP błędem 628, mimo poprawnych zapisanych danych. Skrypt używa więc bezpośrednio `RasDial`. Jeśli i to się nie uda, otwiera Ustawienia VPN i czeka do 2 minut, aż klikniesz „Połącz”.
- W trakcie samego łączenia (kilka sekund) Esc nie działa – można przerwać przez Ctrl+C.
- Metryka 100 zakłada, że lokalne karty mają metrykę automatyczną (zwykle 25–55). Jeśli ręcznie ustawiłeś karcie wyższą metrykę, DNS VPN-a nadal będzie miał pierwszeństwo – test to pokaże.
