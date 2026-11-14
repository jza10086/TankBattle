# M24 铁鹰防线原型　B，正式接入另立任务

来源：2026-11-07 架构审查及其最后实施记录。整理日期：2026-11-14。下列待办保留原状态；实施前核对本包源码与工作区，不以历史检查代替本次验收。

[共享 G01–G03 任务](../../../protocols/godot_party_default_protocol/doc/godot_party_default_protocol_development.md) · [包说明](gp_tank_battle_guide.md)


包：`gp_tank_battle`，`playable:false`；运行根为 `prototype/project.godot`。定位：[prototype/scripts/main.gd](../prototype/scripts/main.gd)、`network.gd`、`battle.gd`。

- [ ] 保留 UI/network/battle 分层及“本地菜单不暂停服务器”语义；补显式类型，固定八声音池和声音资源入场景。
- [ ] 独立原型的输入/连接设置与正式接入分开。未来接入时让 PartyAPI 拥有正式连接，不能再启动一套原型网络；在完成之前不改 playable 或适配器声明。
- [ ] 既有固定地图布局保留，实时破坏状态和对局坦克仍由模型维护。HUD 固定控件保持可编辑，阶段/比分模板与默认语言资源统一。

验证：原型双端入房、准备、移动/炮弹、基地受损、菜单、返回房间和再战；公网体验另验。

## 人工验收待办

保留自 2026-11-05 场景审查，后续记录未明确关闭的人工事项：公网和真人对抗待人工验收。
