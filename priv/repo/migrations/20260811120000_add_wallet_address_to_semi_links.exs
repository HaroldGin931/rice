defmodule Rice.Repo.Migrations.AddWalletAddressToSemiLinks do
  use Ecto.Migration

  # Semi 的 `/oauth/userinfo` 在 `wallet` scope 下返回 `wallet_address`
  # (= Semi 侧的 `user.evm_chain_address`)。rice 一直请求着这个 scope,
  # 也一直收到这个值,但只塞进自己的 session cookie 给调试首页用,从不落库 ——
  # 于是个人页想显示钱包地址时无处可取。这一列就是那个落点。
  #
  # 可空:用户可能没绑钱包,或者授权时没给 wallet scope。
  # EVM 地址是 42 字符,留到 128 是为了以后接别的链地址格式不用再改表。
  def change do
    alter table(:semi_links) do
      add :wallet_address, :string, size: 128
    end
  end
end
