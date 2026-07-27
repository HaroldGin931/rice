ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Rice.Repo, :manual)

# 附件存储在测试里用 Mox 打桩 —— 单元测试不该依赖磁盘状态。
Mox.defmock(Rice.Files.StorageMock, for: Rice.Files.Storage)
Mox.defmock(Rice.PDSMock, for: Rice.PDS.Api)
Mox.defmock(Rice.NotificationsMock, for: Rice.Notifications)
