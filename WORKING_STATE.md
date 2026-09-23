# Working State - 2026-08-31 (updated 2026-09-23)

## README: добавлены поддерживаемые протоколы (2026-09-23)
- В описание добавлена строка о поддерживаемых протоколах:
  - `README.md` (EN): «**Supported protocols:** AmneziaWG, AmneziaWG 3.0»;
  - `README.ru.md` (RU): «**Поддерживаемые протоколы:** AmneziaWG, AmneziaWG 3.0»;
  - описание репозитория на GitHub обновлено через `gh repo edit»
    (добавлено «Supported protocols: AmneziaWG, AmneziaWG 3.0»).
- Правки только текстовые (README); код панели не менялся.
- Коммит: см. git log.

## Panel: флаг страны в карточке сервера (2026-09-23)
- В карточке Server (Location) рядом со страной показывается флаг. `/api/geo` возвращает
  country + code; из ISO-кода строится `<img>` на flagcdn.com (`flagImg()`).
- Первая версия использовала эмодзи-флаги, но на Windows они не рисуются (видны буквы «PL»)
  — заменено на картинки с flagcdn (w24, `onerror`-скрытие, `loading="lazy"`); фолбэк —
  название страны без флага.
- Изменены `index.html` + пересобран `PANEL_B64` в установщике
  (`embedded == index.html: True`, 99068 символов); `node --check` OK, 12 тестов логики флага OK.
- Опубликовано на GitHub (коммит eefb130 и далее).

## README: описание — убрано ограничение «только 3.x» (2026-09-23)
- Уточнение «AmneziaWG 3.x» из описания **убрано** (см. предыдущую запись): панель работает
  и с серверами AmneziaWG 2.0 (amnezia-api строит конфиг из параметров сервера как есть),
  так что «только 3.x» вводило в заблуждение:
  - `README.md` (EN) и `README.ru.md` — строка описания снова «AmneziaVPN / AmneziaWG»;
  - описание репозитория на GitHub возвращено в прежний вид через `gh repo edit`.
- Правки только текстовые (README); код панели не менялся, PANEL_B64/скриншоты не затрагивались.
- Коммит: см. git log.

## README: описание — панель для AmneziaWG 3.x (2026-09-23, отменено)
- В описание добавлено уточнение, что панель предназначена для **AmneziaWG 3.x**:
  - `README.md` (EN) и `README.ru.md` — строка описания: «AmneziaVPN / **AmneziaWG 3.x**»;
  - описание репозитория на GitHub обновлено через `gh repo edit`
    («…for AmneziaVPN / AmneziaWG 3.x in wg-easy style…»).
- Правки только текстовые (README); код панели не менялся, PANEL_B64/скриншоты не затрагивались.
- Коммит: см. git log.

## License: CC BY-NC-SA → MIT (2026-09-23)
- По решению пользователя (против «продажи» он не возражает, но хочет попасть в каталоги
  и убрать барьеры) лицензия сменена на **MIT**:
  - `LICENSE` — официальный текст MIT, Copyright (c) 2026 Kalinin Vitaliy;
  - футер панели: «…is licensed under the MIT License», ссылка opensource.org/licenses/MIT;
  - `README.md` (EN) и `README.ru.md` — секция лицензии обновлены;
  - `PANEL_B64` в установщике пересобран: `embedded == index.html: True`
    (97680 символов, декод 73260 байт), LF сохранён (CRLF=0), токены PLACEHOLDER /
    __SERVER_COUNTRY__ на месте, «Donate» нет;
  - GitHub Release v2.1 — заметки обновлены на MIT (см. ниже).
- Коммит: `—` (см. git log).

## GitHub: README-языки, скриншоты и Release v2.1 (2026-09-23)
- README на двух языках: английский стал основным `README.md`, русский — `README.ru.md`
  (история сохранена через `git mv`; переключатель языка в шапке обоих файлов).
- Скриншоты панели (тёмная/светлая тема, 1320x880) добавлены в `docs/screenshots/`:
  сделаны headless Edge по локальному мок-серверу (временный `mock_panel.js` с
  демо-клиентами, не коммитится); в README обеих версий добавлена секция «Скриншоты».
  Проверка изображения моделью недоступна — проверялось программно: PNG 1320x880,
  `--dump-dom` подтвердил `data-theme="dark"`/`light`, все 5 мок-клиентов, футер.
- **GitHub Release v2.1** создан: https://github.com/kalininvv1974/amnezia-vpn-panel/releases/tag/v2.1
  (прикреплены `install-amnezia-panel.sh` и `uninstall-amnezia-panel.sh`).
- Репозиторий отмечен звёздочкой (HTTP 204) от аккаунта kalininvv1974.
- Коммиты: `76e2bac` (README.en.md), `3d0d958` (eng main README + README.ru.md),
  `e6055da` (скриншоты в README).

## GitHub: подготовка публичного релиза (2026-09-23)
- Репозиторий: **amnezia-vpn-panel**, public. Проект подготовлен к публикации:
  - **API-ключ**: убран встроенный дефолтный ключ — при Enter установщик теперь
    генерирует случайный (`openssl rand -hex 16`, fallback `od`), баланс if/fi 25/25;
  - **Данные замаскированы**: реальный хостнейм сервера в WORKING_STATE.md заменён
    заглушкой; private-памятка `Настройка безопасности.txt` и `*.working` исключены
    из репозитория через `.gitignore`;
  - Добавлены: `LICENSE` (CC BY-NC-SA 4.0, официальный текст) и публичная версия
    `README.md` (возможности, установка, лицензия);
  - Проверки: `embedded == index.html: True` (PANEL_B64 97700), `node --check` OK,
    секреты/хостнеймы не найдены, LF во всех файлах.
- Опубликовано: `git init` + коммит + релиз на GitHub.
- **Репозиторий: https://github.com/kalininvv1974/amnezia-vpn-panel** (public, ветка `main`).
  Теги: vpn, amnezia, amneziawg, vpn-panel, wireguard, nginx, nodejs, wg-easy.

## RELEASE: финальная проверка пакета (2026-09-23)
- Пользователь подтвердил: «всё, это релиз». Панель передана в финальном виде.
- Установщик: версия в баннере обновлена с `v2` на `v2.1`.
- Полный прогон валидации:
  - `node --check` обоих inline-скриптов панели + вшитого auth `server.js` — OK;
  - `embedded == index.html: True` (PANEL_B64 = 97700 символов, декод 73275 байт),
    токены `PLACEHOLDER` / `__SERVER_COUNTRY__` на месте, футер (by Kalinin Vitaliy,
    margin-top:auto) присутствует, «Donate» в панели нет;
  - баланс if/fi установщика 24/24, case/esac 2/2, циклы 1/1; деинсталлятор 11/11,
    циклы 1/1 — все heredoc-регионы исключены из подсчёта;
  - LF сохранён (CRLF=0) во всех трёх файлах.
- На сервер не развёрнуто: запустить `bash install-amnezia-panel.sh` или заменить
  `/var/www/html/index.html` на обновлённый (футер + имя автора).

## Panel update: футер как в wg-easy (2026-09-23)
- Внизу панели добавлен футер: `Amnezia VPN Panel © <год> by Kalinin Vitaliy is licensed
  under CC BY-NC-SA 4.0` (лицензия — ссылка на creativecommons.org/licenses/by-nc-sa/4.0).
  «Donate» убран по просьбе — текста «Donate» в панели нет.
- Год подставляется динамически (`#footer-year` через `new Date().getFullYear()`).
- `.footer` выведен поверх экрана входа (`z-index: 10001`, `< login-overlay`),
  чтобы копирайт был виден всегда, как в wg-easy; `body` переведён на flex-колонку
  (`min-height: 100vh` + `margin-top: auto` у футера) — на экране входа футер
  прижат к низу окна, на основной странице остаётся после контента.
- Конфликтов с sed установщика нет (нет `|`, `PLACEHOLDER`, `__SERVER_COUNTRY__`).
- Проверки: `embedded == index.html: True`; токены на месте; `node --check` обоих
  inline-скриптов OK; LF сохранён (CRLF=0). PANEL_B64 обновлён (97700 символов).
- Не развёрнуто — для появления футера нужен перезапуск установщика.

## Panel update: favicon во вкладке браузера (2026-09-23)
- Добавлены `<link rel="icon">` + `apple-touch-icon` в head `index.html` через
  inline SVG data-URI (без отдельных файлов на сервере): оранжевый скруглённый
  квадрат (#F80) + тёмный щит + оранжевая замочная скважина.
- Проверки: URI не содержит `|`/`PLACEHOLDER`/`__SERVER_COUNTRY__` (не конфликтует
  с sed установщика); `embedded == index.html: True`; if/fi 24/24; `node --check` OK;
  файлы в LF. PANEL_B64 обновлён (96452 символа).
- Не развёрнуто — для появления иконки нужно перезапустить установщик.

## Деплой подтверждён пользователем (2026-09-23)
- Установщик отработал полностью, панель развёрнута на сервере (ПАНЕЛЬ.ПРИМЕР.EXAMPLE).
- Location в панели показывает страну (Kazakhstan); вход через форму (логин/пароль),
  все функции панели работают. Панель активна.

## Bugfix: CRLF в install-amnezia-panel.sh (2026-09-23)
- **Симптом**: `bash install-amnezia-panel.sh` на сервере сыпал
  `$'\r': command not found` / `syntax error near unexpected token $'in\r'`.
- **Причина**: правка Python-скриптом в текстовом режиме на Windows перевела все
  переводы строк локального файла в CRLF (615 строк). Сервер получил CRLF-версию.
- **Решение**: файл сконвертирован обратно в LF (`index.html` и uninstall были LF).
  На сервере: `sed -i 's/\r$//' install-amnezia-panel.sh && bash install-amnezia-panel.sh`
  (или залить актуальный файл заново).
- Проверки после конвертации: `embedded == index.html: True`, декод 71140 байт,
  токены на месте, if/fi 24/24, `node --check` панели и auth-сервиса OK, CRLF=0.

## Bugfix: stale-guard ломал вшитую панель (2026-09-23)
- **Симптом**: установщик на сервере писал «ОШИБКА: панель не вшита в скрипт и
  index.html не найден рядом», хотя панель в скрипт вшита (при этом GeoIP работал:
  «Регион сервера (geoip): Kazakhstan»).
- **Причина**: в `install-amnezia-panel.sh` была заглушка
  `PANEL_B64 != "<предыдущая_версия_base64>"`. `regenerate_panel.py` при каждом
  прогоне обновлял literal заглушки на *предыдущее* значение `PANEL_B64`.
  Повторный прогон без изменения `index.html` делал literal равным самому
  `PANEL_B64` → условие «панель вшита» становилось ложным.
- **Решение**: заглушка убрана. Условие теперь `if [ -n "$PANEL_B64" ]; then`
  (панель вшита, если base64 непустой; актуальность гарантирует regenerate,
  который всегда запускается при изменении `index.html`). `regenerate_panel.py`
  и `verify_embed.py` переписаны без stale-guard.
- Проверки: `embedded == index.html: True`; декод вшитой панели = 71140 байт,
  содержит `PLACEHOLDER` и `__SERVER_COUNTRY__`; if/fi установщика 24/24,
  деинсталлятора 11/11; `node --check` панели и auth-сервиса OK.

## Panel update: Location через рантайм GeoIP в auth-сервисе (2026-09-23)
- **Симптом**: после установки карточка Location показывала «Server-1» вместо страны —
  на этапе установки запрос к geoip-сервисам с сервера не прошёл (сервисы блокируют
  датацентровые IP/недоступны с сети сервера).
- **Решение — страна определяется на лету прямо в auth-сервисе** (`127.0.0.1:4002`,
  Node, без зависимостей):
  - Новый эндпоинт `/geo`: `GET → {"country","code","detected"}`. Запрос уходит
    **с самого сервера** (поэтому возвращается расположение сервера, а не клиента),
    фолбэки: `https://ipwho.is/` → `http://ip-api.com/json/` → `https://ipapi.co/json/`,
    кэш на 6 часов, прогрев при старте сервиса, фоновая перепроверка при просрочке.
  - nginx: `location = /api/geo` (exact) с `auth_request /_auth` — доступен только
    с валидной сессией, как остальной API.
  - Панель: `loadGeo()` берёт `/api/geo` первым, затем зашитую при установке
    `serverCountry`, затем `s.region` из API. Сбой `/api/geo` не ломает загрузку.
- Установщик: детекция при install дополнена третьим сервисом
  (`https://ipapi.co/json/`, у него страна в `country_name`), парсер упрощён до
  `country_name || country`; при недоступности выводится предупреждение
  («локация определится при открытии панели»).
- Проверки: `node --check` (панель и auth-сервис) OK; локальный e2e-тест auth-сервиса:
  `/geo → {"country":"Poland","code":"PL","detected":true}` (и без cookie, и с cookie),
  `/login` 200+cookie, `/status` 200, `/logout` 200; `embedded == index.html: True`;
  баланс if/fi установщика 24/24, деинсталлятора 11/11.
- Не развёрнуто на сервере — ждёт запуска установщика.

## Panel redesign "like wg-easy" (2026-09-23)
- **Только оформление** (`index.html`): тёмная тема в стиле wg-easy + оранжевый акцент `#F80`.
- Верхняя панель (sticky header) с логотипом и названием, справа кнопка «Выйти»
  (id `btn-logout` и вся логика сохранены).
- Переоформлены: карточки, инфо-сетка сервера (акцентные значения), строка клиента,
  зелёный тумблер включения (checked = активен), кнопка «+ Add Client» — оранжевая
  (класс сменился с `btn-success` на `btn-primary`, тексты не менялись), бейджи,
  сообщения `#msg`, форма входа и QR-модалка.
- **Все id/классы/JS-логика сохранены** — функционал не изменён.
- Проверки: `node --check` обоих скриптов OK; PANEL_B64 перегенерирован
  (`embedded == index.html: True`); баланс if/fi установщика 20/20 и деинсталлятора 11/11.
- Не развёрнуто на сервере — ждёт правок пользователя и запуска установщика.

## Panel update: light theme + add-client modal (2026-09-23)
- **Светлая/тёмная тема с переключателем в шапке** (кнопка `#btn-theme` с иконками
  солнце/луна). Выбор сохраняется в `localStorage('pnl_theme')`; по умолчанию — из
  `prefers-color-scheme`. Все цвета вынесены в CSS-переменные `:root` +
  `html[data-theme="light"]` (инлайн-стили QR-модалки используют те же `var(--...)`).
- **Добавление клиента — модальное окно как в wg-easy**: кнопка «+ Add Client»
  в карточке открывает модалку с полем имени (`#name-input` перенесён внутрь),
  кнопками `#btn-add-submit` (+ Add Client) и `#btn-add-cancel` (Cancel), закрытие
  по клику на подложку. Логика `createClient` и вызов API не менялись; модалка
  закрывается после успешного создания.
- Проверки пройдены: `node --check` OK, `embedded == index.html: True`,
  if/fi 20/20 и 11/11.

## Panel update: server region by IP (2026-09-23)
- **Карточка Server → Location теперь показывает страну по внешнему IP сервера**
  (вместо метки `region` из API, например «Server-1»). Подпись переименована
  «Region» → «Location».
- Установщик при установке запрашивает GeoIP (`https://ipwho.is/`, fallback
  `http://ip-api.com/json/` — запрос с самого сервера, поэтому возвращается
  расположение сервера, а не клиента), парсит страну через `node` и подставляет
  в панель `sed`-ом вместо токена `__SERVER_COUNTRY__` (в `index.html` панели:
  `var serverCountry = '__SERVER_COUNTRY__'`, отображается как `serverCountry ||
  s.region || '?'`).
- Если GeoIP недоступен — токен не заменяется, панель показывает старый `region`
  из API (не ломается).
- Проверки: `node --check` OK, `embedded == index.html: True`, баланс if/fi
  установщика 24/24 (было 20/20 — добавлены 4 geoip-блока), деинсталлятор 11/11.

## New panel login (2026-09-23)
- **Убраны Basic Auth / браузерный попап**: вход теперь через **форму внутри панели**.
- Добавлен **auth-сервис** `amnezia-panel-auth.service` (Node, без зависимостей,
  `127.0.0.1:4002`): `/login`, `/logout`, `/status`, `/_auth` (для nginx `auth_request`).
  Пароль проверяется через PBKDF2-SHA256 (100k итераций), конфиг `/etc/amnezia-panel/auth.json`
  (salt/hash/secret для HMAC-подписи сессии), токен живёт до закрытия браузера (session-cookie,
  HttpOnly, SameSite=Strict) + лимит 12ч.
- nginx vhost `panel`: `auth_basic` заменён на `auth_request /_auth` для `location /api/`
  (все запросы к API — только с валидной сессией); `/api/auth/login|logout|status` — публичные.
- `index.html`: форма входа (логин+пароль), кнопка «Выйти», обработка 401 (сессия истекла →
  снова форма). **Пароль запрашивается заново при каждом новом открытии браузера.**
- Тест auth-сервиса пройден локально (401/200/401 по cookie).

## Security cleanup (2026-09-22)
- **Секреты удалены из этого файла**: пароль root, IP сервера, SSH-порт и API-ключ.
  Храните их в менеджере паролей, а не в коде/заметках.
- **Вход в панель — по логину/паролю**: nginx через `auth_request` защищает `/api`;
  сам логин/пароль вводится в форме внутри панели (см. секцию выше).
- **API переведён на loopback**: `FASTIFY_ROUTES=127.0.0.1:4001` — наружу доступен
  только через nginx (и под сессией).
- **Инсталлятор**: запрос API-ключа (Enter = встроенный, >= 32 символов), логина/пароля
  панели (Enter = admin / случайный пароль), загрузка deb nginx по HTTPS, README
  приведён к реальности.

## AmneziaWG 5.0.1.5 config compatibility (2026-09-23)
- Сверено по исходникам тега `5.0.1.5` (configKeys.h, awgProtocolConfig, awgConfigurator):
  имена JSON-ключей в vpn://-ссылке (`client_ip`, `client_priv_key`, `server_pub_key`,
  `psk_key`, `hostName`, `port`, `last_config`, `Jc`-`I5`, `HeaderProtectionKey`) — совпадают.
- Панель теперь переносит в .conf **все** параметры AWG3 из `last_config`, которые раньше
  вырезала: `MTU`, `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`,
  `RejectAfterTime`, `KeepaliveTimeout`, `MaxHandshakeAttempts`, `RandomTrailers`,
  `DisableCookies`; `PersistentKeepalive`/`AllowedIPs` берутся из конфига (fallback 25 и
  `0.0.0.0/0, ::/0`). Тестировано на образце конфига 5.0.1.5 (node).
- Исправления внесены в `index.html` + перегенерирован `PANEL_B64` в установщике
  (проверка `embedded == index.html: True`).

## What was fixed (earlier)
- **localStorage key mismatch**: `createClient` saved vpn:// URL as `vpn_<PublicKey>`,
  but `showQr`/`downloadConfig` looked up by `vpn_<username>`. Keys never matched.
  Fixed: now both use `vpn_<username>`.
- **deleteClient was passing username instead of PublicKey** to the API.
  Fixed: passes `peerId` from DOM.
- **API key not replaced** on server (was PLACEHOLDER after upload). Fixed with `sed`.

## Files
- `index.html` — актуальная панель (внутренний ключ зашит, можно переопределить через `?key=`)
- `install-amnezia-panel.sh` — установщик с вшитой base64-панелью (синхронна с index.html)
- `uninstall-amnezia-panel.sh` — деинсталлятор
- `*.working` — **снапшоты до введения формы входа (2026-09-23)**, т.е. актуальные
  файлы на момент Basic Auth — backup для отката новой схемы входа (вернуть и
  перезапустить установщик).

## Key facts (не секретные)
- API port: 4001, бинд на 127.0.0.1 (FASTIFY_ROUTES=127.0.0.1:4001)
- Auth port: 4002 (auth-сервис панели, systemd `amnezia-panel-auth.service`)
- Container: amnezia-awg2, UDP 31509
- Panel: /var/www/html/index.html (nginx port 80 -> 4001, вход через форму в панели)
- Auth config: /etc/amnezia-panel/auth.json (PBKDF2 hash + secret)
- API systemd: amnezia-api.service
- Config: /opt/amnezia/awg/awg0.conf
- SSH: вход только по ключу (см. Настройка безопасности.txt)

## To rollback (до правок безопасности)
Вернуть `.working`-файлы вместо основных, например:
```
cp index.html.working index.html
cp install-amnezia-panel.sh.working install-amnezia-panel.sh
```
Затем на сервере выполнить те же действия вручную (Basic Auth, FASTIFY_ROUTES),
т.к. старые версии без этих правок.