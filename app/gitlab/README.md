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

gitlab-rake gitlab:elastic:index_projects_status
gitlab-rake gitlab:elastic:info rake

### console

```
gitlab-rails console
```
