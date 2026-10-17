# LoRA Dataset Studio na Vast.ai

Zestaw, który uruchamia [LoRA Dataset Studio](https://github.com/perfectgf/lora-dataset-studio) **w całości na wynajętej karcie graficznej Vast.ai**: generowanie zdjęć (ComfyUI), selekcję, opisy (JoyCaption / Ollama), trening LoRA (ai-toolkit) i testy checkpointów. Na swoim komputerze potrzebujesz tylko przeglądarki.

Wszystko, co ważne (zbiory danych, modele, zainstalowane programy), leży na **trwałym wolumenie**. Możesz więc skasować instancję po każdej sesji, płacić tylko za dysk, a przy następnym uruchomieniu wszystko jest na swoim miejscu.

> Ten zestaw nie jest częścią projektu LoRA Dataset Studio. Pobiera i instaluje oficjalny kod z [perfectgf/lora-dataset-studio](https://github.com/perfectgf/lora-dataset-studio) (gałąź `v2`). LDS jest objęty licencją [PolyForm Noncommercial](https://github.com/perfectgf/lora-dataset-studio/blob/v2/LICENSE), czyli tylko do użytku niekomercyjnego.

## Spis treści

1. [Co dostajesz](#co-dostajesz)
2. [Ile to kosztuje](#ile-to-kosztuje)
3. [Krok 1: szablon na Vast.ai (jednorazowo)](#krok-1-szablon-na-vastai-jednorazowo)
4. [Krok 2: wynajem maszyny z wolumenem](#krok-2-wynajem-maszyny-z-wolumenem)
5. [Krok 3: pierwsze uruchomienie](#krok-3-pierwsze-uruchomienie)
6. [Krok 4: Setup w studiu](#krok-4-setup-w-studiu)
7. [Krok 5: praca od A do Z](#krok-5-praca-od-a-do-z)
8. [Krok 6: koniec sesji (Stop czy Destroy?)](#krok-6-koniec-sesji-stop-czy-destroy)
9. [Krok 7: powrót do pracy](#krok-7-powrót-do-pracy)
10. [Kopia zapasowa](#kopia-zapasowa)
11. [Aktualizacje](#aktualizacje)
12. [Polecenia pomocnicze](#polecenia-pomocnicze)
13. [Bezpieczeństwo](#bezpieczeństwo)
14. [Rozwiązywanie problemów](#rozwiązywanie-problemów)
15. [Ustawienia zaawansowane](#ustawienia-zaawansowane)
16. [Co jest przetestowane, a co nie](#co-jest-przetestowane-a-co-nie)

## Co dostajesz

| Element | Gdzie działa | Uwagi |
|---|---|---|
| **LoRA Dataset Studio** | kafelek „LoRA Dataset Studio” w portalu instancji | Cały interfejs: zbiory danych, Image Bank, selekcja, opisy, trening, Test Studio |
| **ComfyUI** | ta sama karta GPU | Generowanie zdjęć (Klein, Krea 2 Edit i inne) i testy checkpointów. Prekonfigurowane w studiu |
| **ai-toolkit** | ta sama karta GPU | Trening LoRA „lokalnie” na wynajętej karcie oraz opisy JoyCaption. Prekonfigurowany w studiu |
| **Ollama** | ta sama karta GPU | Lokalny model wizyjny: kadrowanie, przycinanie głowy, krótkie opisy |
| **Trwały wolumen** | `/workspace` | Dane, modele i środowiska Pythona przetrwają skasowanie instancji |

Studio samo pilnuje, żeby te programy nie biły się o pamięć karty: przed treningiem zwalnia modele ComfyUI, a w trakcie treningu wstrzymuje generowanie.

## Ile to kosztuje

Ceny na Vast.ai ustalają właściciele maszyn i zmieniają się codziennie. Orientacyjnie (październik 2026):

| Co | Koszt | Kiedy płacisz |
|---|---|---|
| RTX 4090 (24 GB) | ok. 0,30–0,50 $/h | tylko gdy instancja działa |
| RTX 5090 (32 GB) | ok. 0,40–0,80 $/h | tylko gdy instancja działa |
| Wolumen 200 GB | zwykle ok. 10–20 $/miesiąc (zależy od hosta: 0,01–0,20 $/GB) | cały czas, dopóki go nie usuniesz |

- **Pierwsze uruchomienie** to ok. 20–30 minut instalacji (szacunek), a potem pobieranie modeli z ekranu Setup (np. ok. 30 GB dla Klein).
- **Kolejne uruchomienia** na tym samym wolumenie trwają kilka minut, bo nic nie instaluje się od nowa.
- Karta 24 GB wystarcza do generowania i treningu większości rodzin (Z-Image, SDXL, Krea 2, FLUX.2 Klein 4B). FLUX.2 Klein **9B** potrzebuje do treningu 32–48 GB.

## Krok 1: szablon na Vast.ai (jednorazowo)

Szablon mówi Vast.ai, jaki obraz uruchomić i jaki skrypt instalacyjny pobrać. Robisz go raz i potem tylko wybierasz.

1. Załóż konto na [cloud.vast.ai](https://cloud.vast.ai/) i doładuj saldo (np. 10–20 $ na start).
2. Wejdź w **Templates**, znajdź oficjalny szablon **ComfyUI** (autor: Vast.ai) i otwórz go do edycji (ikona ołówka). Zapisz go jako własny szablon, np. „LoRA Dataset Studio”. Możesz też utworzyć nowy szablon od zera i wpisać wszystko z tabeli poniżej.
3. Ustaw pola jak w tabeli:

| Pole | Wartość |
|---|---|
| **Image Path:Tag** | `vastai/comfy:v0.41.0-cuda-12.9-py312` (ta wersja jest sprawdzona w teście tego repo) |
| **Launch Mode** | Jupyter (+ SSH), jak w oficjalnym szablonie ComfyUI |
| **On-start Script** | `entrypoint.sh` |
| **Container disk** | 50 GB |
| **Volume** | dodaj wolumen (*Add recommended volume settings*): rozmiar **200 GB**, ścieżka montowania **`/workspace`** |

4. W polu **Docker Options** (porty i zmienne) wklej całość w jednej linii:

```text
-p 1111:1111 -p 8080:8080 -p 8384:8384 -p 72299:72299 -p 8188:8188 -p 5050:5050 -e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=1 -e JUPYTER_DIR=/ -e DATA_DIRECTORY=/workspace/ -e PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:5050:15050:/:LoRA Dataset Studio|localhost:8188:18188:/:ComfyUI|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing" -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/Ezekieloo/lora-dataset-studio-vast/main/provision.sh -e COMFYUI_ARGS="--disable-auto-launch --port 18188 --enable-cors-header"
```

Jeśli Twój panel ma osobne pola na porty i zmienne środowiskowe, wpisz je osobno:

- **Porty:** `1111`, `8080`, `8384`, `72299`, `8188`, **`5050`** (to jest port studia)
- **Zmienne:**

| Zmienna | Wartość |
|---|---|
| `PROVISIONING_SCRIPT` | `https://raw.githubusercontent.com/Ezekieloo/lora-dataset-studio-vast/main/provision.sh` |
| `PORTAL_CONFIG` | `localhost:1111:11111:/:Instance Portal\|localhost:5050:15050:/:LoRA Dataset Studio\|localhost:8188:18188:/:ComfyUI\|localhost:8080:18080:/:Jupyter\|localhost:8080:8080:/terminals/1:Jupyter Terminal\|localhost:8384:18384:/:Syncthing` |
| `OPEN_BUTTON_PORT` | `1111` |
| `OPEN_BUTTON_TOKEN` | `1` |
| `JUPYTER_DIR` | `/` |
| `DATA_DIRECTORY` | `/workspace/` |
| `COMFYUI_ARGS` | `--disable-auto-launch --port 18188 --enable-cors-header` |

5. Zapisz szablon.

Różnice względem oficjalnego szablonu ComfyUI są tylko trzy: port `5050`, wpis „LoRA Dataset Studio” w `PORTAL_CONFIG` oraz adres naszego skryptu w `PROVISIONING_SCRIPT`. Nazwy przycisków w panelu Vast.ai mogą się nieco różnić od opisu, ale pola są te same.

## Krok 2: wynajem maszyny z wolumenem

1. Wejdź w **Search** i wybierz swój szablon „LoRA Dataset Studio”.
2. Ustaw filtry:
   - **GPU:** RTX 4090 lub RTX 5090, liczba kart: 1
   - dla **RTX 5090:** *Max CUDA* co najmniej **13.0** (ai-toolkit na kartach serii 50 wymaga nowego sterownika)
   - **Verified**, *Reliability* powyżej 98%, *Inet Down* co najmniej 500 Mbps (szybsze pobieranie obrazu i modeli)
3. **Wybieraj maszyny z kilkoma takimi samymi kartami** (np. 4× lub 8× 4090). Wolumen jest przypisany do jednej fizycznej maszyny, więc przy powrocie do pracy masz większą szansę, że któraś karta będzie wolna.
4. Przy wynajmie upewnij się, że wolumen ma **200 GB** i ścieżkę **`/workspace`**, potem kliknij **Rent**.

## Krok 3: pierwsze uruchomienie

1. Na liście instancji kliknij **Open**. Otworzy się *Instance Portal*.
2. Instalacja trwa ok. 20–30 minut: pobranie obrazu (~10 GB), środowisko studia, ai-toolkit, Ollama. Postęp widać w portalu w zakładce z logami (*provisioning*).
3. Gdy się skończy, kliknij kafelek **LoRA Dataset Studio**. Studio otworzy się w nowej karcie.

Jeśli kafelek pokazuje błąd albo pustą stronę, instalacja jeszcze trwa. Odczekaj i odśwież. Stan sprawdzisz w **Jupyter Terminal** poleceniem `lds-status`.

## Krok 4: Setup w studiu

Przy pierwszym wejściu studio pokaże ekran **Setup**. ComfyUI, ai-toolkit i Ollama są już wpisane w ustawieniach, więc zostaje pobrać modele:

1. **Modele do generowania**: np. Klein (model, enkoder tekstu, VAE, LoRA; razem ok. 30 GB). Trafiają do `/workspace/ComfyUI/models` na wolumenie.
2. **Węzły ComfyUI** (np. LanPaint, Krea 2 Edit): po ich instalacji otwórz **Jupyter Terminal** i wpisz:
   ```bash
   comfy-restart
   ```
   To doinstaluje ich zależności i zrestartuje ComfyUI. Inaczej studio będzie pokazywać „nodes missing”.
3. **Model Ollama** do opisów (ok. 7 GB): przycisk w Setup.
4. **Klucze API** wpisz w ustawieniach studia (zapisują się na wolumenie w `/workspace/lds-data/.env`). Do treningu FLUX / Krea 2 potrzebny jest **token Hugging Face** z zaakceptowaną licencją tych modeli.
5. **Wtyczki** (Plugins → Store): przy instalacji studio poprosi o *plugin admin token*. Wypisze go polecenie:
   ```bash
   lds-token
   ```

Wtyczka **Cloud training** nie jest potrzebna, bo trening idzie na tej samej karcie.

## Krok 5: praca od A do Z

Tak jak lokalnie, tylko na wynajętej karcie:

1. **Nowy zbiór danych** (Character / Concept / Style).
2. **Generowanie** zdjęć w ComfyUI albo import własnych (przeciągnij pliki lub ZIP do przeglądarki).
3. **Selekcja**: zostaw / odrzuć, przycięcie, ocena twarzy, znaki wodne.
4. **Opisy**: JoyCaption albo Ollama.
5. **Trening**: lane „local” uruchamia ai-toolkit na tej samej karcie.
6. **Test Studio**: porównanie checkpointów i siły LoRA.
7. **Pobranie wyniku**: plik `.safetensors` albo ZIP zbioru danych prosto do przeglądarki.

Szczegóły funkcji opisuje [dokumentacja LDS](https://github.com/perfectgf/lora-dataset-studio/blob/v2/docs/guide/workflow.md).

**Wysyłanie dużych plików:** używaj zwykłego linku z portalu (przycisk **Open**). Link Cloudflare (`*.trycloudflare.com`) ma limit 100 MB na jedno wysłanie.

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
3. Po kilku minutach otwórz kafelek **LoRA Dataset Studio**. Wszystko jest tam, gdzie było.

**Brak wolnej karty na tej maszynie?** Poczekaj albo skopiuj wolumen na inną maszynę (`vastai clone volume` w CLI Vast.ai) lub odtwórz dane z kopii zapasowej.

## Kopia zapasowa

Wolumen leży na dysku jednej maszyny. Jeśli właściciel ją wyłączy na stałe, dane przepadną, więc **trzymaj kopię tego, czego nie da się odtworzyć**:

- **Najważniejszy jest folder `/workspace/lds-data`**: zbiory danych, baza, checkpointy, ustawienia. Modele i programy da się pobrać ponownie.
- **Vast Cloud Sync**: w ustawieniach konta Vast.ai (*Cloud Connections*) podłącz Backblaze B2, Google Drive, S3 lub Dropbox. Potem na karcie instancji użyj *Cloud Copy* dla `/workspace/lds-data`.
- **Kopia w studiu**: Settings → Maintenance → pełna kopia (backup), do pobrania przez przeglądarkę. Kopia nie zawiera kluczy API.
- **Gotowe LoRA** pobieraj na bieżąco albo publikuj na Hugging Face / Civitai wtyczkami studia.

## Aktualizacje

- **Studio:** w aplikacji *Settings → Update & restart*. Po restarcie zależności doinstalują się same.
- **Ten zestaw:** nic nie robisz. Szablon wskazuje na najnowszy `provision.sh`, więc nowa instancja pobiera aktualną wersję.
- **ai-toolkit:** w Jupyter Terminal:
  ```bash
  git -C /workspace/ai-toolkit pull && lds-reprovision
  ```
- **ComfyUI:** jest kopiowany z obrazu tylko przy pierwszym uruchomieniu na pustym wolumenie. Później aktualizujesz go przez ComfyUI-Manager albo `git -C /workspace/ComfyUI pull`, a potem `comfy-restart`.

## Polecenia pomocnicze

Wpisuj je w **Jupyter Terminal** (kafelek w portalu instancji):

| Polecenie | Co robi |
|---|---|
| `lds-status` | Stan studia, ComfyUI i Ollamy, wersja studia, zajętość wolumenu, kosz, pamięć GPU |
| `lds-token` | Wypisuje *plugin admin token* do instalowania wtyczek |
| `lds-restart` | Restartuje studio |
| `comfy-restart` | Doinstalowuje zależności węzłów ComfyUI i restartuje ComfyUI |
| `lds-reprovision` | Ponownie uruchamia instalację (bezpieczne: pomija to, co już jest) |
| `supervisorctl tail -f lds` | Log studia na żywo (Ctrl+C kończy) |

## Bezpieczeństwo

- **Studio nasłuchuje tylko lokalnie** (`127.0.0.1:15050`). Z internetu da się do niego dostać wyłącznie przez proxy Vast (Caddy) na porcie `5050`, które wymaga logowania Vast. Przycisk **Open** loguje automatycznie. Link Cloudflare też przechodzi przez to logowanie.
- **ComfyUI (8188)** też jest za logowaniem Vast.
- **Nie udostępniaj linków z tokenem.** Kto ma dostęp do studia, widzi Twoje klucze API, może usuwać zbiory danych i uruchamiać zadania na Twojej karcie.
- **Nie dodawaj portów `5050` ani `8188` do `AUTH_EXCLUDE`**, bo wyłączysz w ten sposób logowanie.
- **Stałe hasło:** jeśli chcesz wchodzić bez przycisku *Open*, ustaw w szablonie zmienną `WEB_PASSWORD`. Login to `vastai`.

## Rozwiązywanie problemów

| Objaw | Co zrobić |
|---|---|
| Kafelek studia nie działa (błąd 502 albo pusta strona) | Instalacja jeszcze trwa. Sprawdź logi w portalu albo `lds-status` |
| W logach jest „Provisioning failed” | Przeczytaj ostatnie linie z `[lds-vast] ERROR`. Często to chwilowy błąd sieci: zrestartuj instancję (instalacja ruszy ponownie) albo uruchom `lds-reprovision` |
| Brak kafelka „LoRA Dataset Studio” | W szablonie brakuje wpisu w `PORTAL_CONFIG` albo portu `5050`. Skrypt sam dopisuje wpis do portalu, ale port musi być w szablonie. Bez portu działa tylko link Cloudflare |
| Studio pokazuje „nodes missing” po instalacji węzłów | `comfy-restart` |
| Instalacja wtyczki odrzucona („plugin admin token”) | `lds-token` i wklej wynik na stronie Plugins |
| Na RTX 5090 trening kończy się błędem CUDA („no kernel image”) | Sterownik hosta jest za stary. Wybierz maszynę z *Max CUDA* ≥ 13.0 |
| Kończy się miejsce na wolumenie | `lds-status`. Usunięte w studiu pliki trafiają do kosza `/workspace/.Trash-0`; opróżnisz go `rm -rf /workspace/.Trash-0/*` |
| Gated model: 401/403 przy pobieraniu | Zaakceptuj licencję modelu na Hugging Face i wpisz token HF w ustawieniach studia |

Logi: portal instancji → zakładka z logami (`lds`, `lds-ollama`, `comfyui`, *provisioning*).

## Ustawienia zaawansowane

Te zmienne możesz dodać do szablonu (`-e NAZWA=wartość`):

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
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
  - czy studio, ComfyUI i Ollama odpowiadają;
  - czy studio jest dostępne tylko po zalogowaniu i czy ustawienia są poprawnie wpisane.
- **Czego test nie sprawdza:** pracy na prawdziwej karcie, czyli wersji CUDA torch, treningu i generowania na GPU, ani samego panelu Vast.ai. Pierwsze uruchomienie na Vast.ai jest pierwszym testem z kartą. Jeśli coś pójdzie nie tak, logi z portalu powiedzą, który krok zawiódł.

## Licencje

- Ten zestaw (skrypty i instrukcja): [MIT](LICENSE).
- [LoRA Dataset Studio](https://github.com/perfectgf/lora-dataset-studio): PolyForm Noncommercial 1.0.0, tylko do użytku niekomercyjnego.
- [ComfyUI](https://github.com/Comfy-Org/ComfyUI): GPL-3.0. [ai-toolkit](https://github.com/ostris/ai-toolkit) i [Ollama](https://github.com/ollama/ollama): MIT.
- Modele mają własne licencje (np. FLUX.2 Klein, Krea 2). Sprawdź je przed użyciem.
