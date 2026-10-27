# LoRA Dataset Studio na Vast.ai

Zestaw, który uruchamia [LoRA Dataset Studio](https://github.com/perfectgf/lora-dataset-studio) **w całości na wynajętej karcie graficznej Vast.ai**: generowanie zdjęć (ComfyUI), selekcję, opisy (JoyCaption / Ollama), trening LoRA (ai-toolkit) i testy checkpointów. Na swoim komputerze potrzebujesz tylko przeglądarki.

**Jak to wygląda na co dzień:** wynajmujesz maszynę z szablonu, klikasz **Open** i jesteś w studiu. Przy każdym starcie studio samo aktualizuje się do najnowszej wersji od autora i dociąga modele, których ta wersja potrzebuje, a których jeszcze nie ma na dysku.

Wszystko, co ważne (zbiory danych, modele, zainstalowane programy), leży na **trwałym wolumenie**. Możesz więc skasować instancję po każdej sesji, płacić tylko za dysk, a przy następnym uruchomieniu wszystko jest na swoim miejscu.

> Ten zestaw nie jest częścią projektu LoRA Dataset Studio. Pobiera i instaluje oficjalny kod z [perfectgf/lora-dataset-studio](https://github.com/perfectgf/lora-dataset-studio) (gałąź `v2`). LDS jest objęty licencją [PolyForm Noncommercial](https://github.com/perfectgf/lora-dataset-studio/blob/v2/LICENSE), czyli tylko do użytku niekomercyjnego.

## Spis treści

1. [Co dostajesz](#co-dostajesz)
2. [Ile to kosztuje](#ile-to-kosztuje)
3. [Krok 1: szablon na Vast.ai (jednorazowo)](#krok-1-szablon-na-vastai-jednorazowo)
4. [Krok 2: wynajem maszyny z wolumenem](#krok-2-wynajem-maszyny-z-wolumenem)
5. [Krok 3: pierwsze uruchomienie](#krok-3-pierwsze-uruchomienie)
6. [Krok 4: klucze i to, czego automat nie zrobi](#krok-4-klucze-i-to-czego-automat-nie-zrobi)
7. [Krok 5: praca od A do Z](#krok-5-praca-od-a-do-z)
8. [Krok 6: koniec sesji (Stop czy Destroy?)](#krok-6-koniec-sesji-stop-czy-destroy)
9. [Krok 7: powrót do pracy](#krok-7-powrót-do-pracy)
10. [Modele: co pobiera się samo](#modele-co-pobiera-się-samo)
11. [Aktualizacje](#aktualizacje)
12. [Kopia zapasowa](#kopia-zapasowa)
13. [Portal instancji i terminal](#portal-instancji-i-terminal)
14. [Polecenia pomocnicze](#polecenia-pomocnicze)
15. [Bezpieczeństwo](#bezpieczeństwo)
16. [Rozwiązywanie problemów](#rozwiązywanie-problemów)
17. [RunPod zamiast Vast.ai](#runpod-zamiast-vastai)
18. [Ustawienia zaawansowane](#ustawienia-zaawansowane)
19. [Co jest przetestowane, a co nie](#co-jest-przetestowane-a-co-nie)

## Co dostajesz

| Element | Gdzie działa | Uwagi |
|---|---|---|
| **LoRA Dataset Studio** | przycisk **Open** na karcie instancji | Cały interfejs: zbiory danych, Image Bank, selekcja, opisy, trening, Test Studio |
| **ComfyUI** | ta sama karta GPU | Silniki generowania Klein i Krea 2 Edit oraz testy checkpointów. Prekonfigurowane w studiu |
| **ai-toolkit** | ta sama karta GPU | Trening LoRA „lokalnie” na wynajętej karcie oraz opisy JoyCaption. Prekonfigurowany w studiu |
| **Ollama** | ta sama karta GPU | Lokalny model wizyjny: kadrowanie, przycinanie głowy, krótkie opisy |
| **Automatyczne modele** | w tle po starcie | Studio samo pobiera wszystko, co wymienia na ekranie Setup ([szczegóły](#modele-co-pobiera-się-samo)) |
| **Automatyczne aktualizacje** | przy każdym starcie | Najnowsza wersja studia od autora |
| **Trwały wolumen** | `/workspace` | Dane, modele i środowiska Pythona przetrwają skasowanie instancji |

Studio samo pilnuje, żeby te programy nie biły się o pamięć karty: przed treningiem zwalnia modele ComfyUI, a w trakcie treningu wstrzymuje generowanie.

## Ile to kosztuje

Ceny na Vast.ai ustalają właściciele maszyn i zmieniają się codziennie. Orientacyjnie (październik 2026):

| Co | Koszt | Kiedy płacisz |
|---|---|---|
| RTX 4090 (24 GB) | ok. 0,30–0,50 $/h | tylko gdy instancja działa |
| RTX 5090 (32 GB) | ok. 0,40–0,80 $/h | tylko gdy instancja działa |
| Wolumen 300 GB | zależy od hosta: od kilku do ponad 150 $/miesiąc (0,01–0,60 $/GB) | cały czas, dopóki go nie usuniesz |

> ⚠️ **Na Vast.ai cenę dysku ustala każdy host osobno** i potrafi ona być wielokrotnie wyższa od ceny karty. Przed wynajmem sprawdź w ofercie cenę za GB miesięcznie (szukaj poniżej ok. 0,10 $/GB). Jeśli zależy Ci na przewidywalnej, niskiej cenie dysku, zobacz [RunPod zamiast Vast.ai](#runpod-zamiast-vastai): tam wolumen sieciowy kosztuje stałe 0,07 $/GB miesięcznie.

- **Pierwsze uruchomienie:** ok. 20–30 minut instalacji programów. Potem w tle pobiera się ok. 140 GB modeli, co zajmuje od kilkunastu minut do ponad godziny, zależnie od łącza maszyny. Studio działa już w tym czasie.
- **Kolejne uruchomienia** na tym samym wolumenie trwają kilka minut, bo nic nie instaluje się ani nie pobiera od nowa.
- **Karta 24 GB** wystarcza do generowania i treningu większości rodzin (Z-Image, SDXL, Krea 2, FLUX.2 Klein 4B). FLUX.2 Klein **9B** potrzebuje do treningu 32–48 GB.

## Krok 1: szablon na Vast.ai (jednorazowo)

Szablon mówi Vast.ai, jaki obraz uruchomić i jaki skrypt instalacyjny pobrać. Robisz go raz i potem tylko wybierasz.

1. Załóż konto na [cloud.vast.ai](https://cloud.vast.ai/) i doładuj saldo (np. 20 $ na start).
2. Wejdź w **Templates**, znajdź oficjalny szablon **ComfyUI** (autor: Vast.ai) i otwórz go do edycji (ikona ołówka). Zapisz go jako własny szablon, np. „LoRA Dataset Studio”. Możesz też utworzyć nowy szablon od zera i wpisać wszystko z tabel poniżej.
3. Ustaw pola:

| Pole | Wartość |
|---|---|
| **Image Path:Tag** | `vastai/comfy:v0.41.0-cuda-12.9-py312` (ta wersja jest sprawdzona w teście tego repo) |
| **Launch Mode** | Jupyter (+ SSH), jak w oficjalnym szablonie ComfyUI |
| **On-start Script** | `entrypoint.sh` |
| **Container disk** | 50 GB |
| **Volume** | dodaj wolumen (*Add recommended volume settings*): rozmiar **300 GB**, ścieżka montowania **`/workspace`** |

4. W polu **Docker Options** (porty i zmienne) wklej całość w jednej linii:

```text
-p 1111:1111 -p 8080:8080 -p 8384:8384 -p 72299:72299 -p 8188:8188 -p 5050:5050 -e OPEN_BUTTON_PORT=5050 -e OPEN_BUTTON_TOKEN=1 -e JUPYTER_DIR=/ -e DATA_DIRECTORY=/workspace/ -e PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:5050:15050:/:LoRA Dataset Studio|localhost:8188:18188:/:ComfyUI|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing" -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/Ezekieloo/lora-dataset-studio-vast/main/provision.sh -e COMFYUI_ARGS="--disable-auto-launch --port 18188 --enable-cors-header"
```

Jeśli Twój panel ma osobne pola na porty i zmienne środowiskowe, wpisz je osobno:

- **Porty:** `1111`, `8080`, `8384`, `72299`, `8188`, **`5050`** (to jest port studia, obowiązkowy)
- **Zmienne:**

| Zmienna | Wartość |
|---|---|
| `PROVISIONING_SCRIPT` | `https://raw.githubusercontent.com/Ezekieloo/lora-dataset-studio-vast/main/provision.sh` |
| `OPEN_BUTTON_PORT` | `5050` (przycisk **Open** otwiera od razu studio) |
| `PORTAL_CONFIG` | `localhost:1111:11111:/:Instance Portal\|localhost:5050:15050:/:LoRA Dataset Studio\|localhost:8188:18188:/:ComfyUI\|localhost:8080:18080:/:Jupyter\|localhost:8080:8080:/terminals/1:Jupyter Terminal\|localhost:8384:18384:/:Syncthing` |
| `OPEN_BUTTON_TOKEN` | `1` |
| `JUPYTER_DIR` | `/` |
| `DATA_DIRECTORY` | `/workspace/` |
| `COMFYUI_ARGS` | `--disable-auto-launch --port 18188 --enable-cors-header` |

5. **Opcjonalnie, ale wygodnie:** dopisz swoje klucze jako zmienne, np. `-e HF_TOKEN=hf_...` i `-e CIVITAI_API_KEY=...`. Wtedy także modele wymagające klucza pobiorą się bez Twojego udziału. Trzymaj taki szablon jako **prywatny**. Możesz też wpisać klucze raz w ustawieniach studia ([krok 4](#krok-4-klucze-i-to-czego-automat-nie-zrobi)).
6. Zapisz szablon.

Względem oficjalnego szablonu ComfyUI zmieniasz tylko cztery rzeczy: port `5050`, `OPEN_BUTTON_PORT=5050`, wpis „LoRA Dataset Studio” w `PORTAL_CONFIG` oraz adres naszego skryptu w `PROVISIONING_SCRIPT`. Nazwy przycisków w panelu Vast.ai mogą się nieco różnić od opisu, ale pola są te same.

## Krok 2: wynajem maszyny z wolumenem

1. Wejdź w **Search** i wybierz swój szablon „LoRA Dataset Studio”.
2. Ustaw filtry:
   - **GPU:** RTX 4090 lub RTX 5090, liczba kart: 1
   - dla **RTX 5090:** *Max CUDA* co najmniej **13.0** (ai-toolkit na kartach serii 50 wymaga nowego sterownika)
   - **Verified**, *Reliability* powyżej 98%, *Inet Down* co najmniej 500 Mbps (od tego zależy, jak szybko pobiorą się modele)
3. **Wybieraj maszyny z kilkoma takimi samymi kartami** (np. 4× lub 8× 4090). Wolumen jest przypisany do jednej fizycznej maszyny, więc przy powrocie do pracy masz większą szansę, że któraś karta będzie wolna.
4. Przy wynajmie upewnij się, że wolumen ma **300 GB** i ścieżkę **`/workspace`**, potem kliknij **Rent**.

## Krok 3: pierwsze uruchomienie

1. Na liście instancji kliknij **Open**. Otworzy się LoRA Dataset Studio. Dopóki trwa instalacja, zamiast studia zobaczysz stronę oczekiwania; odśwież ją po kilku minutach.
2. Instalacja programów trwa ok. 20–30 minut: obraz (~10 GB), środowisko studia, ai-toolkit, Ollama.
3. Gdy studio się otworzy, **modele pobierają się już w tle**. Możesz od razu zakładać zbiory danych i importować zdjęcia, a generowanie ruszy, gdy dojdą pliki silnika. Postęp widać w ekranie Setup studia albo poleceniem `lds-status` w terminalu ([jak go otworzyć](#portal-instancji-i-terminal)).

Na ekranie Setup ComfyUI, ai-toolkit i Ollama są już wpisane, więc wystarczy go przejść. Modeli nie musisz klikać, bo pobierają się same.

## Krok 4: klucze i to, czego automat nie zrobi

- **Silnik do generowania:** wystarczy **jeden**, Klein albo Krea 2 Edit. Klein pobiera się bez żadnego klucza. Krea 2 Edit to drugi, dodatkowy silnik, a jego LoRA tożsamości pochodzi z Civitai i wymaga **klucza API Civitai**.
- **Klucze API** wpisz w ustawieniach studia. Zapisują się na wolumenie w `/workspace/lds-data/.env`, więc robisz to raz.
  - **Civitai:** potrzebny dla LoRA Krea 2 Edit.
  - **Hugging Face:** potrzebny do treningu modeli z licencją do zaakceptowania (FLUX, Krea 2, FLUX.2 Klein). Na stronie modelu na Hugging Face kliknij akceptację licencji.
  - Po wpisaniu kluczy brakujące modele dociągną się przy następnym starcie. Jeśli chcesz od razu, wpisz w terminalu `lds-models`.
- **Wtyczki** (Plugins → Store): przy instalacji studio poprosi o *plugin admin token*. Wypisze go polecenie `lds-token`.
- Wtyczka **Cloud training** nie jest potrzebna, bo trening idzie na tej samej karcie.

## Krok 5: praca od A do Z

Tak jak lokalnie, tylko na wynajętej karcie:

1. **Nowy zbiór danych** (Character / Concept / Style) i zdjęcie referencyjne.
2. **Generowanie** wariantów w Klein albo Krea 2 Edit, lub import własnych zdjęć (przeciągnij pliki albo ZIP do przeglądarki).
3. **Selekcja**: zostaw / odrzuć, przycięcie, ocena twarzy, znaki wodne.
4. **Opisy**: JoyCaption albo Ollama.
5. **Trening**: lane „local” uruchamia ai-toolkit na tej samej karcie. Model bazowy danej rodziny pobiera się przy pierwszym treningu.
6. **Test Studio**: porównanie checkpointów i siły LoRA.
7. **Pobranie wyniku**: plik `.safetensors` albo ZIP zbioru danych prosto do przeglądarki.

Szczegóły funkcji opisuje [dokumentacja LDS](https://github.com/perfectgf/lora-dataset-studio/blob/v2/docs/guide/workflow.md).

**Wysyłanie dużych plików:** używaj zwykłego linku z przycisku **Open**. Link Cloudflare (`*.trycloudflare.com`) ma limit 100 MB na jedno wysłanie.

## Krok 6: koniec sesji (Stop czy Destroy?)

| Akcja | Co się dzieje | Koszt |
|---|---|---|
| **Stop** | Karta przestaje liczyć. Kontener i wolumen zostają | Płacisz za dysk kontenera i wolumen. Ponowny start może czekać, jeśli ktoś zajmie tę kartę |
| **Destroy** (instancji) | Kontener znika, **wolumen zostaje** z całą zawartością | Płacisz tylko za wolumen |

**Zalecenie: po każdej sesji rób Destroy instancji, a wolumen zostaw.** Wszystko, co ważne, jest na wolumenie, a następne uruchomienie odtwarza resztę w kilka minut.

> ⚠️ Nie usuwaj **wolumenu**, chyba że chcesz skasować wszystko: zbiory, modele i checkpointy.

## Krok 7: powrót do pracy

1. W panelu Vast znajdź swój wolumen (sekcja *Storage / Volumes*) i wybierz **Rent instance using this volume**. Zobaczysz tylko oferty z tej samej maszyny.
2. Wybierz szablon „LoRA Dataset Studio” i kliknij **Rent**.
3. Po kilku minutach kliknij **Open**. Studio jest zaktualizowane, a modele i dane są tam, gdzie były.

**Brak wolnej karty na tej maszynie?** Poczekaj albo skopiuj wolumen na inną maszynę (`vastai clone volume` w CLI Vast.ai) lub odtwórz dane z kopii zapasowej.

## Modele: co pobiera się samo

Po każdym starcie instancji zestaw prosi **instalator wbudowany w studio** (ten sam, którego używają przyciski na ekranie Setup) o wszystko, czego brakuje. Lista modeli pochodzi więc zawsze od autora studia: gdy po aktualizacji pojawi się nowy model albo zmieni się wersja pliku, następny start go pobierze. Pliki, które już są na wolumenie, są pomijane.

| Zestaw (`LDS_MODELS`) | Co zawiera | Ok. rozmiar |
|---|---|---|
| **`all`** (domyślny) | Klein (model, enkoder tekstu, VAE, LoRA), Krea 2 Edit z węzłami, węzły LanPaint, model wizyjny Ollama, narzędzia jakości (detektor znaków wodnych, wyszukiwanie SigLIP2) **oraz** modele Test Studio wszystkich rodzin (FLUX.1, Qwen-Image 2.1, MOSS-Image, Anima i nowe, gdy autor je doda) | ok. 140 GB |
| `generate` | to samo bez modeli Test Studio | ok. 60 GB |
| `none` | nic, modele klikasz sam w Setup | 0 |

- **Nie pobiera się z góry:** modele bazowe do treningu (Z-Image, Krea 2, FLUX). ai-toolkit pobiera je sam przy pierwszym treningu danej rodziny (każda to ok. 20–25 GB) do `/workspace/.hf_home`. Niektóre wymagają tokena Hugging Face.
- **JoyCaption** (ok. 7 GB) pobiera się przy pierwszym użyciu.
- Po instalacji nowych węzłów ComfyUI zestaw sam doinstalowuje ich zależności i restartuje ComfyUI.
- Log pobierania: `supervisorctl tail -f lds-models` w terminalu. Ponowne uruchomienie: `lds-models`. Podgląd bez pobierania: `lds-models plan`.

## Aktualizacje

- **Studio:** aktualizuje się **samo przy każdym starcie instancji** (najnowsza wersja z gałęzi `v2` od autora). Po aktualizacji zestaw doinstalowuje nowe zależności i pobiera modele, których wymaga nowa wersja. W trakcie pracy możesz też użyć *Settings → Update & restart* w studiu. Jeśli wolisz zostać przy danej wersji, ustaw w szablonie `LDS_AUTO_UPDATE=0`.
- **Wtyczki:** w studiu, *Plugins → Updates*.
- **Ten zestaw:** nic nie robisz. Szablon wskazuje na najnowszy `provision.sh`, więc nowa instancja pobiera aktualną wersję.
- **ai-toolkit:** w terminalu `git -C /workspace/ai-toolkit pull && lds-reprovision`.
- **ComfyUI:** jest kopiowany z obrazu tylko przy pierwszym uruchomieniu na pustym wolumenie. Później aktualizujesz go przez ComfyUI-Manager albo `git -C /workspace/ComfyUI pull`, a potem `comfy-restart`.

## Kopia zapasowa

Wolumen leży na dysku jednej maszyny. Jeśli właściciel ją wyłączy na stałe, dane przepadną, więc **trzymaj kopię tego, czego nie da się odtworzyć**:

- **Najważniejszy jest folder `/workspace/lds-data`**: zbiory danych, baza, checkpointy, ustawienia. Modele i programy pobiorą się ponownie same.
- **Vast Cloud Sync**: w ustawieniach konta Vast.ai (*Cloud Connections*) podłącz Backblaze B2, Google Drive, S3 lub Dropbox. Potem na karcie instancji użyj *Cloud Copy* dla `/workspace/lds-data`.
- **Kopia w studiu**: Settings → Maintenance → pełna kopia (backup), do pobrania przez przeglądarkę. Kopia nie zawiera kluczy API.
- **Gotowe LoRA** pobieraj na bieżąco albo publikuj na Hugging Face / Civitai wtyczkami studia.

## Portal instancji i terminal

Przycisk **Open** prowadzi prosto do studia. Portal instancji (logi, Jupyter Terminal, linki Cloudflare) jest na porcie **1111**:

- Na karcie instancji w panelu Vast otwórz listę portów (adres IP instancji). Przy porcie **1111** jest adres w rodzaju `http://IP:NNNNN`, otwórz go w tej samej przeglądarce. Logowanie z przycisku **Open** obowiązuje też tam.
- W portalu kafelek **Jupyter Terminal** otwiera terminal, w którym wpisujesz polecenia z tabeli poniżej.
- Wolisz, żeby **Open** otwierał portal? Ustaw w szablonie `OPEN_BUTTON_PORT=1111`.

## Polecenia pomocnicze

Wpisuj je w **Jupyter Terminal**:

| Polecenie | Co robi |
|---|---|
| `lds-status` | Stan studia, ComfyUI, Ollamy i pobierania modeli, wersja studia, zajętość wolumenu, kosz, pamięć GPU |
| `lds-models` | Pobiera brakujące modele teraz (np. po wpisaniu kluczy). `lds-models plan` tylko pokazuje, co by pobrał |
| `lds-token` | Wypisuje *plugin admin token* do instalowania wtyczek |
| `lds-restart` | Restartuje studio |
| `comfy-restart` | Doinstalowuje zależności węzłów ComfyUI i restartuje ComfyUI |
| `lds-reprovision` | Ponownie uruchamia instalację (bezpieczne: pomija to, co już jest) |
| `supervisorctl tail -f lds` | Log studia na żywo (Ctrl+C kończy). Zamiast `lds` może być `lds-models` lub `comfyui` |

## Bezpieczeństwo

- **Studio nasłuchuje tylko lokalnie** (`127.0.0.1:15050`). Z internetu da się do niego dostać wyłącznie przez proxy Vast (Caddy) na porcie `5050`, które wymaga logowania Vast. Przycisk **Open** loguje automatycznie. Link Cloudflare też przechodzi przez to logowanie.
- **ComfyUI (8188)** też jest za logowaniem Vast.
- **Nie udostępniaj linków z tokenem.** Kto ma dostęp do studia, widzi Twoje klucze API, może usuwać zbiory danych i uruchamiać zadania na Twojej karcie.
- **Klucze w szablonie** (`HF_TOKEN`, `CIVITAI_API_KEY`) trzymaj tylko w **prywatnym** szablonie.
- **Nie dodawaj portów `5050` ani `8188` do `AUTH_EXCLUDE`**, bo wyłączysz w ten sposób logowanie.
- **Stałe hasło:** jeśli chcesz wchodzić bez przycisku *Open*, ustaw w szablonie zmienną `WEB_PASSWORD`. Login to `vastai`.

## Rozwiązywanie problemów

| Objaw | Co zrobić |
|---|---|
| Po kliknięciu **Open** strona oczekiwania nie znika | Instalacja jeszcze trwa (pierwszy start to 20–30 minut). Sprawdź logi w [portalu](#portal-instancji-i-terminal) albo `lds-status` |
| W logach jest „Provisioning failed” | Przeczytaj ostatnie linie z `[lds-vast] ERROR`. Często to chwilowy błąd sieci: zrestartuj instancję (instalacja ruszy ponownie) albo uruchom `lds-reprovision` |
| **Open** nie otwiera studia albo brak kafelka „LoRA Dataset Studio” | Sprawdź szablon. Port `5050` (`-p 5050:5050`) jest **obowiązkowy**: bez niego Vast nie wystawi studia, nawet przez link Cloudflare. Brakujący wpis w `PORTAL_CONFIG` skrypt dopisze sam |
| Silnik Krea 2 Edit nie jest gotowy | Brakuje klucza Civitai dla jego LoRA. Wpisz klucz w ustawieniach studia i uruchom `lds-models` |
| Któryś model się nie pobrał | `supervisorctl tail lds-models` pokaże, który i dlaczego. Po poprawce (klucz, licencja HF, miejsce) uruchom `lds-models` |
| Studio pokazuje „nodes missing” | `comfy-restart` |
| Instalacja wtyczki odrzucona („plugin admin token”) | `lds-token` i wklej wynik na stronie Plugins |
| Po automatycznej aktualizacji coś przestało działać | Ustaw w szablonie `LDS_AUTO_UPDATE=0` i zgłoś problem autorowi studia |
| Na RTX 5090 trening kończy się błędem CUDA („no kernel image”) | Sterownik hosta jest za stary. Wybierz maszynę z *Max CUDA* ≥ 13.0 |
| Kończy się miejsce na wolumenie | `lds-status`. Usunięte w studiu pliki trafiają do kosza `/workspace/.Trash-0`; opróżnisz go `rm -rf /workspace/.Trash-0/*`. Możesz też przełączyć się na `LDS_MODELS=generate` i usunąć nieużywane modele Test Studio |

Logi: portal instancji → zakładka z logami (`lds`, `lds-models`, `lds-ollama`, `comfyui`, *provisioning*).

## RunPod zamiast Vast.ai

Ten sam zestaw działa na [RunPod](https://www.runpod.io/). RunPod uruchamia ten sam obraz `vastai/comfy` jako zwykły kontener, a zmienne poniżej robią to, co na Vast.ai robi sama platforma.

**Dlaczego RunPod:** wolumen sieciowy kosztuje stałe **0,07 $/GB miesięcznie** (200 GB to ok. 14 $), istnieje niezależnie od podów i da się go później powiększyć.

**Ograniczenia RunPod:**
- Pod może działać tylko w centrum danych, w którym leży wolumen.
- Wolumen sieciowy jest wolniejszy od lokalnego dysku, więc pierwsze ładowanie modelu trwa dłużej.
- Proxy RunPod zrywa połączenie po 100 sekundach bez odpowiedzi. Bardzo duże eksporty ZIP i kopie zapasowe mogą się nie zmieścić w tym czasie.

### 1. Wolumen sieciowy

**Storage → Network Volumes → New Network Volume**:
- centrum danych, w którym są dostępne RTX 4090 (np. `EU-RO-1`),
- rozmiar **200 GB** dla zestawu modeli `generate` albo **300 GB** dla `all`.

Istniejący wolumen powiększysz w jego ustawieniach.

### 2. Szablon

**My Templates → New Template**, typ *Pod*, GPU NVIDIA:

| Pole | Wartość |
|---|---|
| **Container Image** | `vastai/comfy:v0.41.0-cuda-12.9-py312` |
| **Container Start Command** | **zostaw puste** (start robi sam obraz) |
| **Container Disk** | 50 GB |
| **Volume Mount Path** | `/workspace` |
| **Expose HTTP Ports** | `5050,8080,1111,8188` |
| **Widoczność** | prywatny |

**Zmienne środowiskowe** (na RunPod wpisuj wartości **bez cudzysłowów**):

| Klucz | Wartość |
|---|---|
| `PROVISIONING_SCRIPT` | `https://raw.githubusercontent.com/Ezekieloo/lora-dataset-studio-vast/main/provision.sh` |
| `OPEN_BUTTON_TOKEN` | **Twoje hasło do logowania**: długie i losowe, np. 32 znaki |
| `PORTAL_CONFIG` | `localhost:1111:11111:/:Instance Portal\|localhost:5050:15050:/:LoRA Dataset Studio\|localhost:8188:18188:/:ComfyUI\|localhost:8080:18080:/:Jupyter` |
| `VAST_TCP_PORT_5050` | `5050` |
| `VAST_TCP_PORT_8080` | `8080` |
| `VAST_TCP_PORT_1111` | `1111` |
| `VAST_TCP_PORT_8188` | `8188` |
| `COMFYUI_ARGS` | `--disable-auto-launch --port 18188 --enable-cors-header` |
| `DATA_DIRECTORY` | `/workspace/` |
| `LDS_MODELS` | `generate` (przy 200 GB) albo `all` (przy 300 GB) |
| `HF_TOKEN`, `CIVITAI_API_KEY` | opcjonalnie. Najlepiej jako *Secrets* RunPod: wartość `{{ RUNPOD_SECRET_nazwa }}` |

Zmienne `VAST_TCP_PORT_*` są obowiązkowe. Bez nich proxy z logowaniem nie wystawi studia ani Jupytera.

### 3. Uruchomienie

1. **Pods → Deploy**: wybierz swój wolumen sieciowy, kartę **RTX 4090** i szablon „LoRA Dataset Studio”, potem **Deploy On-Demand**.
2. Gdy pod działa: **Connect → HTTP Service [Port 5050]**. Otworzy się adres `https://<id-poda>-5050.proxy.runpod.net`.
3. Przeglądarka zapyta o login: **użytkownik `vastai`**, **hasło = wartość `OPEN_BUTTON_TOKEN`**. Pierwszy start (instalacja) trwa ok. 20–40 minut. Do tego czasu zobaczysz stronę oczekiwania.
4. **Jupyter** (pliki i terminal): **Connect → HTTP Service [Port 8080]**, ten sam login. Terminal otworzysz przez **New → Terminal**. Działają w nim polecenia z sekcji [Polecenia pomocnicze](#polecenia-pomocnicze).

### 4. Koniec sesji i powrót

- **Terminate** poda: kontener znika, **wolumen sieciowy zostaje** z całą zawartością. Płacisz tylko za wolumen.
- Następnym razem: **Pods → Deploy** z tym samym wolumenem i szablonem. Start trwa kilka minut, bo wszystko jest już na wolumenie, a studio przy okazji się aktualizuje.

## Ustawienia zaawansowane

Te zmienne możesz dodać do szablonu (`-e NAZWA=wartość`):

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
| `LDS_MODELS` | `all` | Które modele pobierać automatycznie: `all`, `generate`, `none` albo lista nazw akcji z Setup oddzielona przecinkami ([szczegóły](#modele-co-pobiera-się-samo)) |
| `LDS_AUTO_UPDATE` | `1` | `0` = nie aktualizuj studia przy starcie |
| `OPEN_BUTTON_PORT` | `5050` (w szablonie) | `1111` = przycisk **Open** otwiera portal instancji zamiast studia |
| `HF_TOKEN`, `CIVITAI_API_KEY` | (brak) | Klucze dla modeli, które ich wymagają (tylko w prywatnym szablonie) |
| `LDS_REF` | `v2` | Gałąź LoRA Dataset Studio przy pierwszej instalacji |
| `LDS_INSTALL_AITK` | `1` | `0` = bez ai-toolkit (bez lokalnego treningu i JoyCaption) |
| `LDS_INSTALL_OLLAMA` | `1` | `0` = bez Ollamy |
| `OLLAMA_VERSION` | `v0.40.6` | Wersja Ollamy |
| `AITK_REF` | `main` | Commit lub gałąź ai-toolkit przy pierwszej instalacji |
| `LDS_TORCH_BACKEND` | `auto` | Wersja CUDA dla torch w środowisku studia (`cu126`, `cu129`, `cu130`, `cpu`) |
| `WEB_PASSWORD` | (brak) | Stałe hasło do logowania Vast (login `vastai`) |

Układ na wolumenie:

```text
/workspace
├── ComfyUI/               ComfyUI, modele, węzły, wygenerowane obrazy
├── lora-dataset-studio/   studio + jego środowisko Pythona (.venv)
├── lds-data/              zbiory danych, baza, checkpointy, config.json, .env (klucze API)
├── ai-toolkit/            trening + jego środowisko Pythona (.venv)
├── .hf_home/              pobrane modele Hugging Face (trening, JoyCaption)
└── .lds/                  ten zestaw: Python, cache uv, Ollama i jej modele, token wtyczek
```

## Co jest przetestowane, a co nie

- **Automatyczny test** (GitHub Actions, plik `tests/smoke.sh`) uruchamia prawdziwy obraz `vastai/comfy` z tym skryptem na maszynie **bez GPU**. Sprawdza:
  - czy instalacja przechodzi na pustym wolumenie;
  - czy druga instancja na tym samym wolumenie niczego nie instaluje od nowa;
  - czy studio, ComfyUI i Ollama odpowiadają, a studio jest dostępne tylko po zalogowaniu;
  - czy ustawienia są poprawnie wpisane;
  - czy automatyczna aktualizacja się wykonuje;
  - czy automat modeli działa przez instalator studia. Test pobiera mały podzbiór (VAE Klein i węzły LanPaint), bo maszyna testowa nie ma miejsca na 140 GB.
  - czy Jupyter (port 8080) i logowanie hasłem działają za proxy z logowaniem. Test uruchamia kontener tak jak RunPod: zwykły Docker ze zmiennymi `VAST_TCP_PORT_*`.
- **Czego test nie sprawdza:**
  - samego RunPoda (jego proxy i konsoli);
  - pracy na prawdziwej karcie, czyli wersji CUDA torch, treningu i generowania na GPU;
  - pobierania pełnego zestawu modeli;
  - samego panelu Vast.ai i przycisku **Open**.

  Pierwsze uruchomienie na Vast.ai jest pierwszym testem z kartą. Jeśli coś pójdzie nie tak, logi z portalu powiedzą, który krok zawiódł.

## Licencje

- Ten zestaw (skrypty i instrukcja): [MIT](LICENSE).
- [LoRA Dataset Studio](https://github.com/perfectgf/lora-dataset-studio): PolyForm Noncommercial 1.0.0, tylko do użytku niekomercyjnego.
- [ComfyUI](https://github.com/Comfy-Org/ComfyUI): GPL-3.0. [ai-toolkit](https://github.com/ostris/ai-toolkit) i [Ollama](https://github.com/ollama/ollama): MIT.
- Modele mają własne licencje (np. FLUX.2 Klein, Krea 2). Sprawdź je przed użyciem.
