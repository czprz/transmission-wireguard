# transmission-wireguard Architecture

```mermaid
graph TD
  subgraph Pod
    WG[WireGuard Container]
    TX[Transmission Container]
  end
  WG -- shares network --> TX
  WG -- mounts wg0.conf --> Secret[wg0.conf Secret]
  TX -- mounts settings.json --> ConfigMap[settings.json ConfigMap]
  TX -- persistent data --> PVC[PersistentVolumeClaim]
  TX -- web UI --> Ingress[Ingress]
```

- Both containers run in a single Pod for forced VPN routing.
- WireGuard config is provided via Secret or values.
- Transmission settings are provided via ConfigMap.
- Data is persisted via PVC or hostPath.
- Ingress is optional for exposing the web UI.
