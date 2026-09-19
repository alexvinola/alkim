defmodule Khymeia.ProvidersTest do
  use Khymeia.RuntimeCase, async: false

  alias Khymeia.Providers
  alias Khymeia.Providers.Profile
  alias Khymeia.Harness.{Claude, Codex}

  @moduletag :capture_log
  @secret "sk-test_0123456789abcdef"

  @turn %{
    prompt: "hi",
    workspace: "/tmp",
    executable: "/bin/tool",
    model: nil,
    permission_mode: nil,
    resume: nil
  }

  describe "profiles" do
    test "validate settings per provider" do
      assert {:ok, _} =
               Providers.save(%{
                 name: "bedrock-work",
                 harness: :claude,
                 kind: :bedrock,
                 settings: %{"region" => "eu-west-1", "aws_profile" => "work"}
               })

      assert {:error, cs} =
               Providers.save(%{name: "f", harness: :claude, kind: :foundry, settings: %{}})

      assert "set the resource name or the base URL" in errors_on(cs).settings

      assert {:error, cs} =
               Providers.save(%{
                 name: "az",
                 harness: :codex,
                 kind: :azure_openai,
                 settings: %{"base_url" => "https://x.openai.azure.com/openai"},
                 credential: :env,
                 credential_env: "AZ_KEY"
               })

      assert Enum.any?(errors_on(cs).settings, &(&1 =~ "invalid base_url"))

      # Quotes could break the TOML override: rejected.
      assert {:error, _} =
               Providers.save(%{
                 name: "bad",
                 harness: :claude,
                 kind: :bedrock,
                 settings: %{"aws_profile" => ~s(x" -c evil)}
               })

      # Azure OpenAI needs a key (Codex has no Entra ID support).
      assert {:error, cs} =
               Providers.save(%{
                 name: "az2",
                 harness: :codex,
                 kind: :azure_openai,
                 settings: %{"base_url" => "https://x.openai.azure.com/openai/v1"}
               })

      assert errors_on(cs).credential == ["not available for this provider"]
      assert {:error, _} = Providers.save(%{name: "x", harness: :claude, kind: :azure_openai})
    end

    test "Keychain secrets are stored outside the database and removed with the profile" do
      {:ok, p} =
        Providers.save(
          %{
            name: "foundry",
            harness: :claude,
            kind: :foundry,
            settings: %{"resource" => "acme"},
            credential: :keychain
          },
          @secret
        )

      assert {:ok, @secret} = Khymeia.MemorySecrets.get("profile:#{p.id}")

      # Nothing secret in the stored row.
      row = Khymeia.Repo.reload(p)
      refute inspect(Map.from_struct(row)) =~ @secret

      # Saving again without a secret keeps the stored one.
      assert {:ok, _} = Providers.save(p, %{default_model: "claude-sonnet-5"}, "")
      assert {:ok, %{secret: @secret}} = Providers.resolve(p.id)

      {:ok, _} = Providers.delete(p)
      assert {:error, :not_found} = Khymeia.MemorySecrets.get("profile:#{p.id}")
    end

    test "a Keychain profile needs a key" do
      assert {:error, cs} =
               Providers.save(%{
                 name: "k",
                 harness: :claude,
                 kind: :foundry,
                 settings: %{"resource" => "a"},
                 credential: :keychain
               })

      assert errors_on(cs).secret == ["paste the API key to store it in the Keychain"]
    end

    test "resolution reports a missing env credential clearly" do
      {:ok, p} =
        Providers.save(%{
          name: "e",
          harness: :claude,
          kind: :bedrock,
          credential: :env,
          credential_env: "KHYMEIA_TEST_UNSET_VAR"
        })

      assert {:error, "environment variable KHYMEIA_TEST_UNSET_VAR is not set" <> _} =
               Providers.resolve(p.id)

      assert [{:warn, "KHYMEIA_TEST_UNSET_VAR is not set" <> _}] = Providers.readiness(p)
    end
  end

  describe "AWS access keys from a form" do
    # AWS's documented example credentials.
    @akid "AKIAIOSFODNN7EXAMPLE"
    @sak "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

    test "are validated and packed for the Keychain" do
      assert :blank = Providers.pack_aws_keys(%{})

      assert {:ok, "#{@akid}:#{@sak}"} ==
               Providers.pack_aws_keys(%{
                 "aws_access_key_id" => @akid,
                 "aws_secret_access_key" => @sak
               })

      assert {:ok, packed} =
               Providers.pack_aws_keys(%{
                 "aws_access_key_id" => @akid,
                 "aws_secret_access_key" => @sak,
                 "aws_session_token" => "IQoJb3JpZ2luX2VjEXAMPLE+/="
               })

      assert packed =~ ~r/:IQoJ/

      assert {:error, _} =
               Providers.pack_aws_keys(%{
                 "aws_access_key_id" => "nope",
                 "aws_secret_access_key" => @sak
               })

      assert {:error, _} =
               Providers.pack_aws_keys(%{
                 "aws_access_key_id" => @akid,
                 "aws_secret_access_key" => ~s(bad" key)
               })
    end

    test "reach Claude Code as environment variables and override inherited AWS settings" do
      keys = %{access_key_id: @akid, secret_access_key: @sak, session_token: nil}
      provider = %{kind: :bedrock, settings: %{"region" => "us-east-1"}, secret: keys, name: "k"}
      {:ok, %{env: env, args: args}} = Claude.build_command(Map.put(@turn, :provider, provider))

      assert {"AWS_ACCESS_KEY_ID", @akid} in env
      assert {"AWS_SECRET_ACCESS_KEY", @sak} in env
      assert {"AWS_SESSION_TOKEN", false} in env
      assert {"AWS_PROFILE", false} in env
      refute Enum.any?(args, &String.contains?(&1, @sak))
    end

    test "a named AWS profile clears inherited keys so it cannot be overridden silently" do
      provider = %{kind: :bedrock, settings: %{"aws_profile" => "work"}, secret: nil, name: "p"}
      {:ok, %{env: env}} = Claude.build_command(Map.put(@turn, :provider, provider))

      assert {"AWS_PROFILE", "work"} in env
      assert {"AWS_ACCESS_KEY_ID", false} in env
      assert {"AWS_SECRET_ACCESS_KEY", false} in env
      assert {"AWS_BEARER_TOKEN_BEDROCK", false} in env
    end

    test "reach Codex's Bedrock provider through the environment, without a profile" do
      keys = %{
        access_key_id: @akid,
        secret_access_key: @sak,
        session_token: "TOKENEXAMPLE0123456"
      }

      provider = %{
        kind: :bedrock,
        settings: %{"region" => "us-east-1", "aws_profile" => "ignored"},
        secret: keys,
        name: "k"
      }

      {:ok, %{env: env, args: args}} = Codex.build_command(Map.put(@turn, :provider, provider))

      refute Enum.any?(args, &String.contains?(&1, "aws.profile"))
      assert {"AWS_ACCESS_KEY_ID", @akid} in env
      assert {"AWS_SESSION_TOKEN", "TOKENEXAMPLE0123456"} in env
    end

    test "end to end: stored in the Keychain, delivered to the process, never exposed", %{
      workspace: ws
    } do
      {:ok, packed} =
        Providers.pack_aws_keys(%{"aws_access_key_id" => @akid, "aws_secret_access_key" => @sak})

      {:ok, p} =
        Providers.save(
          %{name: "aws-demo", harness: :fake, kind: :demo, credential: :aws_keys},
          packed
        )

      assert [{:ok, "AWS access keys stored in the macOS Keychain"}] = Providers.readiness(p)

      {:ok, session} =
        Runtime.start_session(%{
          harness: "fake@#{p.id}",
          workspace: ws,
          prompt: "x",
          model: "whoami"
        })

      :ok = Runtime.subscribe_session(session.id)
      {_, events} = await_event(session.id, :waiting)

      assert Enum.any?(
               events,
               &(&1.type == :output and &1.data.text == "provider=aws-demo secret=present")
             )

      refute inspect({events, Sessions.get(session.id), Khymeia.Repo.reload(p)}) =~ @sak

      # Forgetting the credential keeps the profile and warns.
      Providers.forget_secret(p)
      assert [{:warn, _}] = Providers.readiness(p)

      assert {:error, "the AWS access keys for aws-demo are not in the Keychain"} =
               Providers.resolve(p.id)
    end

    test "a profile with access keys does not keep an AWS profile name" do
      {:ok, packed} =
        Providers.pack_aws_keys(%{"aws_access_key_id" => @akid, "aws_secret_access_key" => @sak})

      {:ok, p} =
        Providers.save(
          %{
            name: "cb-keys",
            harness: :claude,
            kind: :bedrock,
            credential: :aws_keys,
            settings: %{"region" => "us-east-1", "aws_profile" => "work"}
          },
          packed
        )

      assert p.settings == %{"region" => "us-east-1"}
    end
  end

  describe "Claude Code provider environment" do
    test "Bedrock" do
      provider = %{
        kind: :bedrock,
        settings: %{"region" => "eu-west-1", "aws_profile" => "work"},
        secret: nil,
        name: "b"
      }

      {:ok, %{env: env, args: args}} = Claude.build_command(Map.put(@turn, :provider, provider))

      assert {"CLAUDE_CODE_USE_BEDROCK", "1"} in env
      assert {"AWS_REGION", "eu-west-1"} in env
      assert {"AWS_PROFILE", "work"} in env
      # Other providers are switched off explicitly.
      assert {"CLAUDE_CODE_USE_FOUNDRY", false} in env
      assert {"CLAUDE_CODE_USE_VERTEX", false} in env
      # A named profile wins: inherited bearer tokens are cleared, never set.
      assert {"AWS_BEARER_TOKEN_BEDROCK", false} in env
      refute Enum.any?(args, &String.contains?(&1, "eu-west-1"))
    end

    test "Foundry with an API key only puts the key in the environment" do
      provider = %{kind: :foundry, settings: %{"resource" => "acme"}, secret: @secret, name: "f"}
      {:ok, %{env: env, args: args}} = Claude.build_command(Map.put(@turn, :provider, provider))

      assert {"CLAUDE_CODE_USE_FOUNDRY", "1"} in env
      assert {"ANTHROPIC_FOUNDRY_RESOURCE", "acme"} in env
      assert {"ANTHROPIC_FOUNDRY_API_KEY", @secret} in env
      refute Enum.any?(args, &String.contains?(&1, @secret))
    end

    test "Vertex" do
      provider = %{
        kind: :vertex,
        settings: %{"project_id" => "p1", "region" => "global"},
        secret: nil,
        name: "v"
      }

      {:ok, %{env: env}} = Claude.build_command(Map.put(@turn, :provider, provider))
      assert {"CLAUDE_CODE_USE_VERTEX", "1"} in env
      assert {"ANTHROPIC_VERTEX_PROJECT_ID", "p1"} in env
      assert {"CLOUD_ML_REGION", "global"} in env
    end
  end

  describe "Codex provider overrides" do
    test "Azure OpenAI uses a custom provider through -c, key only in the environment" do
      provider = %{
        kind: :azure_openai,
        settings: %{"base_url" => "https://acme.openai.azure.com/openai/v1/"},
        secret: @secret,
        name: "a"
      }

      {:ok, %{args: args, env: env}} =
        Codex.build_command(%{@turn | model: "my-deployment"} |> Map.put(:provider, provider))

      assert ~s(model_provider="khymeia_azure") in args

      assert ~s(model_providers.khymeia_azure.base_url="https://acme.openai.azure.com/openai/v1") in args

      assert ~s(model_providers.khymeia_azure.env_key="KHYMEIA_AZURE_OPENAI_API_KEY") in args
      assert ~s(model_providers.khymeia_azure.wire_api="responses") in args
      assert ["-m", "my-deployment"] == Enum.slice(args, Enum.find_index(args, &(&1 == "-m")), 2)
      assert env == [{"KHYMEIA_AZURE_OPENAI_API_KEY", @secret}]
      refute Enum.any?(args, &String.contains?(&1, @secret))
    end

    test "Amazon Bedrock uses the built-in provider" do
      provider = %{
        kind: :bedrock,
        settings: %{"region" => "eu-central-1", "aws_profile" => "work"},
        secret: nil,
        name: "b"
      }

      {:ok, %{args: args}} = Codex.build_command(Map.put(@turn, :provider, provider))

      assert ~s(model_provider="amazon-bedrock") in args
      assert ~s(model_providers.amazon-bedrock.aws.region="eu-central-1") in args
      assert ~s(model_providers.amazon-bedrock.aws.profile="work") in args
    end
  end

  describe "sessions with a provider profile" do
    test "the profile and its secret reach the harness process, and nothing else", %{
      workspace: ws
    } do
      {:ok, p} =
        Providers.save(
          %{name: "demo", harness: :fake, kind: :demo, credential: :keychain},
          @secret
        )

      {:ok, session} =
        Runtime.start_session(%{
          harness: "fake@#{p.id}",
          workspace: ws,
          prompt: "who am I?",
          model: "whoami"
        })

      :ok = Runtime.subscribe_session(session.id)
      {_, events} = await_event(session.id, :waiting)

      assert Enum.any?(
               events,
               &(&1.type == :output and &1.data.text == "provider=demo secret=present")
             )

      # The secret is nowhere Khymeia keeps or publishes anything.
      {:ok, live, retained} = Runtime.get_session(session.id)
      refute inspect({live, retained, events, Sessions.get(session.id)}) =~ @secret
      assert live.metadata["provider"] == "Demo provider · demo"
    end

    test "each turn resolves the credential again", %{workspace: ws} do
      System.put_env("KHYMEIA_TEST_DEMO_KEY", @secret)

      {:ok, p} =
        Providers.save(%{
          name: "demo-env",
          harness: :fake,
          kind: :demo,
          credential: :env,
          credential_env: "KHYMEIA_TEST_DEMO_KEY"
        })

      {:ok, session} =
        Runtime.start_session(%{
          harness: "fake@#{p.id}",
          workspace: ws,
          prompt: "x",
          model: "whoami"
        })

      :ok = Runtime.subscribe_session(session.id)
      await_event(session.id, :waiting)

      # The key disappears: the next turn fails with a clear message.
      System.delete_env("KHYMEIA_TEST_DEMO_KEY")
      :ok = Runtime.send_message(session.id, "again")
      {failed, _} = await_event(session.id, :failed)
      assert failed.data.error =~ "KHYMEIA_TEST_DEMO_KEY is not set"
    end

    test "a profile must belong to the chosen harness", %{workspace: ws} do
      {:ok, p} = Providers.save(%{name: "cb", harness: :claude, kind: :bedrock})

      assert {:error, {:invalid, %{harness: "unknown provider profile"}}} =
               Runtime.start_session(%{harness: "fake@#{p.id}", workspace: ws, prompt: "x"})

      assert {:error, {:invalid, %{harness: "unknown provider profile"}}} =
               Runtime.start_session(%{
                 harness: "fake@#{Ecto.UUID.generate()}",
                 workspace: ws,
                 prompt: "x"
               })
    end

    test "workflow roles can run through a provider profile", %{workspace: ws} do
      {:ok, p} =
        Providers.save(%{name: "demo-wf", harness: :fake, kind: :demo, credential: :ambient})

      :ok = Khymeia.Workflow.subscribe_all()

      {:ok, run} =
        Khymeia.Workflow.start(%{
          workflow: "simple-coding",
          workspace: ws,
          task: "x",
          roles: %{
            implementer: %{harness: "fake@#{p.id}", model: "whoami"},
            advisor: %{harness: "none"}
          }
        })

      await_workflow(run.id, "workflow.completed")
      [step] = steps(run.id)
      assert step.summary =~ "provider=demo-wf"

      assert Khymeia.Workflow.Store.get_run(run.id).roles["implementer"]["provider"] ==
               "Demo provider · demo-wf"
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
