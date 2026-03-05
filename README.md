# OpenWrt Scripts

## 🇷🇺 Русская версия

Набор скриптов для автоматической настройки и кастомизации роутеров на базе OpenWrt.

Этот репозиторий содержит модульные скрипты, которые упрощают выполнение распространённых задач настройки, таких как установка тем интерфейса, добавление переводов LuCI и настройка специфичных функций роутеров.

Основная цель проекта — предоставить удобную **установку популярных конфигураций OpenWrt одной командой**.

---

# Возможности

На данный момент реализованы следующие функции:

## Установка темы LuCI Argon

Автоматически устанавливает:

- luci-theme-argon  
- luci-app-argon-config  
- русский перевод страницы конфигурации Argon  

Это позволяет быстро изменить внешний вид веб-интерфейса OpenWrt.

---

## Поддержка бокового переключателя на роутерах Cudy TR3000
 
Добавляет поддержку **бокового аппаратного переключателя на роутерах Cudy (например TR3000)**.

Переключатель можно использовать для включения и выключения VPN-маршрутизации через Passwall2.

Поведение:

Switch position | Action
---|---
ON | Включает Passwall2 и запускает сервис
OFF | Выключает Passwall2 и останавливает сервис

Скрипт устанавливает hotplug-обработчик:

```
/etc/hotplug.d/button/10-vpn-switch
```

Этот обработчик реагирует на изменение состояния аппаратного переключателя и выполняет необходимые действия автоматически.

Также используется светодиод питания роутера как индикатор состояния VPN.

---

# Структура репозитория

## assets/

Содержит файлы, которые устанавливаются на роутер.

Например:

- IPK пакеты  
- файлы переводов LuCI  
- конфигурационные скрипты  

## modules/

Скрипты установки, которые скачивают файлы из `assets` и размещают их в нужных местах системы.

Каждый модуль выполняет одну конкретную задачу.

---

# Установка

Модули можно установить напрямую из GitHub.

Пример: установка темы Argon

```
wget -O install_argon.sh https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/modules/install_argon.sh
chmod +x install_argon.sh
sh install_argon.sh
```

Пример: установка поддержки VPN-переключателя

```
wget -O install_vpn_switch.sh https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/modules/install_vpn_switch.sh
chmod +x install_vpn_switch.sh
sh install_vpn_switch.sh
```

---

# Планируемые возможности

Репозиторий находится в активной разработке. Планируется добавить:

- единый установочный скрипт
- автоматические скрипты настройки роутера
- системные твики OpenWrt
- дополнительные кастомизации LuCI
- помощники настройки VPN
- функции для конкретных моделей роутеров

---

# Будущий установщик одной командой

В будущем планируется поддержка установки одной командой:

```
rm -f openwrt-scripts.sh && \
wget https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/openwrt-scripts.sh && \
chmod 755 openwrt-scripts.sh && \
sh openwrt-scripts.sh
```

Этот скрипт будет предоставлять меню установки для всех доступных модулей.

---

# Совместимость

Протестировано с:

- OpenWrt
- Cudy TR3000
- Passwall2

Работа на других роутерах возможна, но не гарантируется.

---

# License

MIT License

---

---

# 🇬🇧 English Version

A collection of scripts for automatic configuration and customization of OpenWrt-based routers.

This repository contains modular scripts that simplify common setup tasks such as installing themes, applying UI translations, and configuring router-specific features.

The goal of this project is to provide a convenient **one-command setup** for frequently used OpenWrt configurations.

---

# Features

Current functionality includes:

## LuCI Argon Theme Installation

Automatically installs:

- luci-theme-argon
- luci-app-argon-config
- Russian translation for Argon configuration page

This allows quick customization of the OpenWrt web interface.

---

## Cudy Router Hardware Switch Integration

Adds support for the **side hardware switch on Cudy routers (for example TR3000)**.

The switch can be used to toggle VPN routing via Passwall2.

Behavior:

Switch position | Action
---|---
ON | Enables Passwall2 and starts the service
OFF | Disables Passwall2 and stops the service

The script installs a hotplug handler:

```
/etc/hotplug.d/button/10-vpn-switch
```

This handler reacts to the hardware switch and performs the required actions automatically.

The router power LED is also used as a visual indicator of VPN state.

---

# Repository Structure

## assets/

Contains files that will be installed on the router.

Examples:

- IPK packages
- LuCI translation files
- configuration scripts

## modules/

Installation scripts that download assets and deploy them to the correct locations in the system.

Each module performs one specific task.

---

# Installation

Modules can be installed directly from GitHub.

Example: install Argon theme

```
wget -O install_argon.sh https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/modules/install_argon.sh
chmod +x install_argon.sh
sh install_argon.sh
```

Example: install VPN switch support

```
wget -O install_vpn_switch.sh https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/modules/install_vpn_switch.sh
chmod +x install_vpn_switch.sh
sh install_vpn_switch.sh
```

---

# Planned Features

This repository is under active development. Planned additions include:

- unified installation script
- automatic router setup scripts
- OpenWrt system tweaks
- additional LuCI customization
- VPN configuration helpers
- router-specific features

---

# Future One-Command Installer

The long-term goal is to support installation using a single command like:

```
rm -f openwrt-scripts.sh && \
wget https://raw.githubusercontent.com/frenzydrive/openwrt-scripts/main/openwrt-scripts.sh && \
chmod 755 openwrt-scripts.sh && \
sh openwrt-scripts.sh
```

This script will provide a menu-driven installer for all available modules.

---

# Compatibility

Tested with:

- OpenWrt
- Cudy TR3000
- Passwall2

Other routers may work but are not guaranteed.

---

# License

MIT License
