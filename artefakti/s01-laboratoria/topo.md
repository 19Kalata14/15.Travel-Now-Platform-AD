# Сесия 1 — Базова лаборатория
Фирма №15: TravelNow Platform AD (онлайн туристическа агенция)

## Сегменти
| Сегмент | Мрежа | VirtualBox | Роля по сценарий |

| WAN | DHCP 10.0.2.0/24 | NAT | Изход към интернет |
| LAN1 | 10.140.0.0/24 | Internal Network (lan1-tech) | LAN-Tech: Booking API 8080, Payment GW 8443 (PCI) |
| LAN2 | 10.141.0.0/24 | Internal Network (lan2-office) | Монтана Call Center (CRM терминал) |

Планирано за следващи сесии: отделен PCI сегмент за Payment GW и
10.142.0.0/24 за партньорския офис в Кюстендил (B2B API).

## Виртуални машини
| VM | vCPU | RAM | Интерфейси | Адреси |
| gw | 1 | 1 GB | enp0s3 (WAN), enp0s8 (LAN1), enp0s9 (LAN2) | 10.0.2.15 (DHCP) / 10.140.0.1 / 10.141.0.1 |
| srv | 2 | 4 GB | enp0s3 (LAN1) | 10.140.0.10, gateway 10.140.0.1 |

ОС: Debian GNU/Linux 13 (trixie).

## Конфигурация на gw
- `/etc/network/interfaces` — DHCP на WAN, статични адреси на LAN1 и LAN2
- `/etc/sysctl.d/99-lab.conf` — `net.ipv4.ip_forward=1` (персистентно)
- `/etc/nftables.conf` — `table ip nat`, chain postrouting,
  правило `oifname "enp0s3" masquerade` (NAT за изходящия трафик)



## Проверки (сесия 1)
- [x] gw и srv стартират, различни hostname и адреси
- [x] srv пингва gw (10.140.0.1) — 0% загуба
- [x] gw има достъп до интернет (ping 1.1.1.1 и deb.debian.org)
- [x] ip forwarding на gw е включен (`net.ipv4.ip_forward = 1`)
- [x] srv излиза в интернет през gw (NAT masquerade)
- [x] Топологията е описана в този файл
