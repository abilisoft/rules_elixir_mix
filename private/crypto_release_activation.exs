# Backend-neutral crypto activation injected before a release runtime.exs.
release_root = System.fetch_env!("RELEASE_ROOT") |> Path.expand()
sdk_root = Path.join(release_root, ".rules_elixir_mix/crypto_sdk")
activation_root =
  System.fetch_env!("RULES_ELIXIR_MIX_CRYPTO_STATE") |> Path.expand()

File.mkdir_p!(activation_root)
isolation_root = Path.join(activation_root, "isolation")
File.mkdir_p!(isolation_root)
isolation_config = Path.join(isolation_root, "openssl.cnf")
File.write!(isolation_config, "")
System.put_env("OPENSSL_CONF", isolation_config)
System.put_env("OPENSSL_MODULES", isolation_root)
System.put_env("FIPS_MODULE_CONF", isolation_config)
config_path = Path.join(release_root, ".rules_elixir_mix/crypto_activation.config")
{:ok, [activation]} = :file.consult(String.to_charlist(config_path))

expand = fn value ->
  value
  |> to_string()
  |> String.replace("{sysroot}", sdk_root)
  |> String.replace("{activation_root}", activation_root)
end

tool = Path.join(sdk_root, to_string(Map.fetch!(activation, :activation_tool)))
args = Enum.map(Map.fetch!(activation, :activation_args), expand)
{output, status} = System.cmd(tool, args, stderr_to_stdout: true)

if status != 0 do
  raise "crypto SDK activation failed with status #{status}: #{output}"
end

activation
|> Map.fetch!(:runtime_environment)
|> Enum.each(fn {key, value} -> System.put_env(to_string(key), expand.(value)) end)
