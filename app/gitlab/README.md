### 登录方式（Authentik 优先）

GitLab 已移除 LDAP 接入，使用 `openid_connect` 默认跳转 Authentik，同时保留本地账户密码登录。以下链接中的 `${DOMAIN}` 需替换为实际域名。

| 用途 | 地址 |
| --- | --- |
| Authentik 应用的 Launch URL / 普通登录入口 | `https://git.${DOMAIN}/users/sign_in` |
| 管理员本地账户密码登录备用入口 | `https://git.${DOMAIN}/users/sign_in?auto_sign_in=false` |

在 Authentik 管理界面中，将 GitLab Application 的 Launch URL 设置为上面的普通登录入口；部署此配置后，该入口会自动发起 OIDC 登录。不要使用 `/users/auth/openid_connect/callback`（回调地址），也不要将 `/users/auth/openid_connect` 作为普通 GET 点击链接，避免认证请求的 POST/CSRF 兼容性问题。现有 OIDC Provider 和回调地址无需更改。

- 管理员应收藏备用入口，并保持 GitLab 管理后台的 Web 密码认证选项启用（`password_authentication_enabled_for_web: true`）；关闭该选项后，备用链接也不能恢复密码登录。
- `auto_sign_in=false` 只绕过自动跳转，不是管理员专属访问控制；其他具备可用本地密码的账户仍可使用此入口。备用管理员必须是可用的本地账户，不应依赖 LDAP。
- 移除 LDAP 配置不会删除已有 GitLab 用户、LDAP identities 或集群中的旧 `ldap-password` Secret。部署前确认用户已能通过 Authentik 登录到原有账户，避免邮箱不匹配造成新建账户；如有 `ldap_blocked` 或旧身份关联问题，应单独排查，不自动批量清理。
- Authentik 会话仍有效时，退出 GitLab 后可能立即重新登录；彻底退出时需要同时退出 Authentik。

仅更新 GitLab（在仓库根目录执行，先核对 `parameter.sh`）：

```bash
bash app/gitlab/install.sh gitlab
```

版本提示处输入当前运行的 GitLab 版本，不要直接接受默认的最新版本，以免意外升级。此次配置更新无需执行 `reinstall`，该模式还会处理其他组件，且缺少本地 chart 缓存时会拉取最新版本。

部署完成后，分别用无痕窗口验证普通入口自动进入 Authentik、已有用户仍登录到原账户且项目权限不变，以及备用入口可用管理员密码登录且不再显示 LDAP 登录入口。

参考：[GitLab OmniAuth 自动登录](https://docs.gitlab.com/integration/omniauth/)、[GitLab Helm 全局配置](https://docs.gitlab.com/charts/charts/globals/)、[Authentik GitLab 集成](https://integrations.goauthentik.io/development/gitlab/)。

### OTP 2FA trouble.

```
PGPASSWORD=${POSTGRES_PASSWORD} psql --dbname=gitlabhq_production --username=admin

SELECT name,username,otp_required_for_login,two_factor_grace_period, require_two_factor_authentication_from_group FROM users;

UPDATE users set otp_required_for_login = 'f' WHERE username = 'root';
```

### Help menu need authenticate

```
diff application_controller.rb application_controller.rb.new -u > application_controller.rb.diff
```

### Disabled 2fa

```
gitlab-rails runner 'User.update_all(otp_required_for_login: false, encrypted_otp_secret: "")'
```

### OpenSSL::Cipher::CipherError

```
DELETE FROM ci_group_variables;
DELETE FROM ci_variables;
UPDATE projects SET runners_token = null, runners_token_encrypted = null;
UPDATE namespaces SET runners_token = null, runners_token_encrypted = null;
UPDATE application_settings SET runners_registration_token_encrypted = null;
UPDATE application_settings SET encrypted_ci_jwt_signing_key = null;
UPDATE ci_runners SET token = null, token_encrypted = null;
UPDATE ci_builds SET token = null, token_encrypted = null;
TRUNCATE web_hooks CASCADE;
```

### restore backup

```
gitlab-rake cache:clear
gitlab-rake db:migrate
gitlab-rake cache:clear
gitlab-rake gitlab:check
```

### console

```
gitlab-rails console
```

gitlab-rake gitlab:elastic:recreate_index
gitlab-rake gitlab:elastic:index
gitlab-rake gitlab:elastic:info rake
gitlab-rake gitlab:elastic:index_projects_status
gitlab-rake gitlab:elastic:projects_not_indexed
gitlab-rake gitlab:elastic:index_projects ID_FROM=1 ID_TO=1000
