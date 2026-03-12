# FaceIDFor6s

Твик для Sileo/Cydia, эмулирующий Face ID на iPhone 6s (iOS 15)
через фронтальную камеру с использованием `Vision.framework`.

---

## Как это работает

| Компонент | Роль |
|---|---|
| `Vision.framework` | Детектирует лицо в кадре с фронтальной камеры |
| `LAContext` hook | Сообщает системе, что биометрия = FaceID и перехватывает `evaluatePolicy:` |
| `BiometricKit` hook | Убирает проверку железа на наличие TrueDepth-сенсора |
| `SBFUserAuthenticationController` hook | Перехватывает запрос биометрии на экране блокировки |
| `FIDCameraFaceScanner` | Захватывает видео с фронтальной камеры, анализирует каждый фрейм |
| `FIDScannerOverlay` | Полноэкранный UI-оверлей с овальной рамкой и сканирующей линией |

Алгоритм аутентификации:
1. Приложение (или SpringBoard) вызывает `[LAContext evaluatePolicy:...]`
2. Хук перехватывает вызов → показывает оверлей-сканер
3. `AVCaptureSession` запускает фронтальную камеру
4. `VNDetectFaceRectanglesRequest` проверяет каждый фрейм
5. Если лицо обнаружено в **8 из N фреймов** за 4 секунды → успех
6. Коллбэк `reply(YES, nil)` возвращается в приложение

---

## Требования

- iPhone 6s (A9) — iOS 15.x
- Джейлбрейк: **Dopamine** (rootless) или **Palera1n** (rootful)
- Substrate/Substitute/libhooker

---

## Сборка

### 1. Установите Theos

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
```

### 2. Клонируйте / распакуйте проект

```bash
cd ~/theos/projects
# Скопируйте папку FaceIDFor6s сюда
cd FaceIDFor6s
```

### 3. Соберите .deb-пакет

```bash
make package FINALPACKAGE=1
```

Готовый `.deb` появится в папке `packages/`.

### 4. Установите через Sileo

- Перенесите `.deb` на устройство (AirDrop / SSH / Filza)
- Откройте в Sileo → «Установить»
- **Respring**

---

## Настройка (опционально)

В `Tweak.x` можно изменить:

```objc
_requiredFrames = 8;   // Количество фреймов с лицом для успеха (↓ = быстрее, ↑ = надёжнее)
```

Таймаут сканирования — `4 * NSEC_PER_SEC` (4 секунды).

---

## Известные ограничения

- Это **не** настоящий Face ID: нет 3D-карты лица, нет IR-подсветки.
  Безопасность значительно ниже оригинала (фото может обмануть).
- На A9 (6s) Vision работает на CPU — небольшая задержка ~0.1–0.2 с на фрейм.
- Некоторые приложения с `DeviceCheck` или `App Attest` могут отказать.

---

## Структура проекта

```
FaceIDFor6s/
├── Makefile                   — параметры сборки Theos
├── Tweak.x                    — весь код (Logos + ObjC)
├── FaceIDFor6s.plist          — фильтр внедрения (SpringBoard + apps)
└── layout/
    └── DEBIAN/
        └── control            — метаданные пакета для dpkg/Sileo
```

---

## Лицензия

MIT — используйте на свой страх и риск.
