defmodule Alkim.Harness.AdaptersTest do
  use ExUnit.Case, async: false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Alkim.Harness
  alias Alkim.Harness.{Capabilities, Claude, Codex, Fake}

  @turn %{
    prompt: "--help; rm -rf /",
    workspace: "/tmp/ws",
    executable: "/usr/local/bin/tool",
    model: nil,
    permission_mode: nil,
    resume: nil
  }

  @interactive %{
    workspace: "/tmp/ws",
    executable: "/usr/local/bin/tool",
    model: nil,
    permission_mode: nil,
    resume: nil,
    session_id: "8d1f1d5e-0b1a-4a52-9f3c-0c2f9a1d7e55"
  }

  test "every adapter implements Alkim.Harness and builds plain argv" do
    for adapter <- [Claude, Codex, Fake] do
      behaviours =
        adapter.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Harness in behaviours
      assert %Capabilities{} = adapter.capabilities()
      assert {:ok, %{executable: "/" <> _, args: args}} = adapter.build_command(@turn)
      assert Enum.all?(args, &is_binary/1)
    end
  end

  describe "Claude" do
    test "passes the prompt as a single argv element after --" do
      {:ok, launch} = Claude.build_command(@turn)

      assert launch.executable == "/usr/local/bin/tool"

      assert ["-p", "--output-format", "stream-json", "--verbose", "--", "--help; rm -rf /"] =
               launch.args
    end

    # The same conversation has to be reachable from both lanes, so Alkim
    # names it on the first turn instead of learning the harness's own id.
    test "names the conversation on the first turn and resumes it afterwards" do
      {:ok, %{args: args}} = Claude.build_command(Map.put(@turn, :session_id, "the-uuid"))
      assert "--session-id" in args and "the-uuid" in args
      refute "--resume" in args

      {:ok, %{args: args}} =
        Claude.build_command(%{@turn | resume: "earlier"} |> Map.put(:session_id, "the-uuid"))

      assert ["--resume", "earlier"] = Enum.take(args, -4) |> Enum.take(2)
      refute "--session-id" in args
    end

    test "adds model, permission mode and resume only when given" do
      turn = %{@turn | model: "opus", permission_mode: "plan", resume: "abc"}
      {:ok, %{args: args}} = Claude.build_command(turn)

      assert ["--model", "opus"] == Enum.slice(args, 4, 2)
      assert "--permission-mode" in args and "plan" in args
      assert ["--resume", "abc", "--", _] = Enum.take(args, -4)
    end

    # Alkim is often started from an agent's own terminal, which exports a
    # family of CLAUDE_* variables. Inheriting them makes the harness believe
    # it is a continuation of that session, and it then behaves — and
    # persists — differently.
    test "clears every inherited CLAUDE_* variable" do
      System.put_env("CLAUDE_CODE_SESSION_ID", "the-session-that-started-alkim")
      System.put_env("CLAUDECODE", "1")
      on_exit(fn -> System.delete_env("CLAUDE_CODE_SESSION_ID") end)

      for {:ok, %{env: env}} <- [
            Claude.build_command(@turn),
            Claude.build_interactive(@interactive)
          ] do
        assert {"CLAUDE_CODE_SESSION_ID", false} in env
        assert {"CLAUDECODE", false} in env
      end
    end

    test "a provider variable is set, not cleared, even though it starts with CLAUDE" do
      provider = %{kind: :bedrock, settings: %{"region" => "eu-west-1"}, secret: nil, name: "aws"}
      {:ok, %{env: env}} = Claude.build_command(Map.put(@turn, :provider, provider))

      assert {"CLAUDE_CODE_USE_BEDROCK", "1"} in env
      refute {"CLAUDE_CODE_USE_BEDROCK", false} in env
    end

    test "the interactive launch names the conversation it will create" do
      {:ok, launch} = Claude.build_interactive(@interactive)

      assert ["--session-id", id] = Enum.take(launch.args, 2)
      assert launch.harness_ref == id

      {:ok, resumed} = Claude.build_interactive(%{@interactive | resume: "earlier"})
      assert ["--resume", "earlier"] = Enum.take(resumed.args, 2)
      assert resumed.harness_ref == "earlier"
    end

    test "parses stream-json events" do
      init = ~s({"type":"system","subtype":"init","session_id":"s-1","model":"m"})
      assert [{:harness_ref, "s-1"}, {:system, "model m"}] = Claude.parse_output(:stdout, init)

      assistant =
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Hi"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}})

      assert [{:message, :assistant, "Hi"}, {:tool, "Bash", "ls -la"}] =
               Claude.parse_output(:stdout, assistant)

      result = ~s({"type":"result","subtype":"success","is_error":false,"num_turns":1})
      assert [{:result, %{"subtype" => "success"}}] = Claude.parse_output(:stdout, result)

      error = ~s({"type":"result","subtype":"error_max_turns","is_error":true})
      assert [{:error, "error_max_turns"}, {:result, _}] = Claude.parse_output(:stdout, error)
    end

    test "reads model aliases from the --model entry of its help text" do
      help = """
      Options:
        --mcp-config <configs...>             Load MCP servers
        --model <model>                       Model for the current session. Provide
                                              an alias for the latest model (e.g.
                                              'fable', 'opus', or 'sonnet') or a
                                              model's full name (e.g.
                                              'claude-fable-5').
        -n, --name <name>                     Set a display name
      """

      assert {:ok, models} = Claude.parse_model_aliases(help)
      assert Enum.map(models, & &1.id) == ["fable", "opus", "sonnet"]
    end

    test "returns :error when the help text does not document aliases" do
      assert :error = Claude.parse_model_aliases("--model <model>  Model to use")
      assert :error = Claude.parse_model_aliases("")
    end

    test "surfaces API retries (how provider misconfiguration shows up)" do
      retry =
        ~s({"type":"system","subtype":"api_retry","attempt":2,"max_retries":10,"error_status":403,"error":"forbidden"})

      assert [{:system, "API retry 2/10 (HTTP 403, forbidden)"}] =
               Claude.parse_output(:stdout, retry)
    end

    test "unknown JSON is ignored, plain text and stderr are passed through" do
      assert [] = Claude.parse_output(:stdout, ~s({"type":"something_new"}))
      assert [{:output, "not json"}] = Claude.parse_output(:stdout, "not json")
      assert [{:stderr, "warn"}] = Claude.parse_output(:stderr, "warn")
    end
  end

  describe "Codex" do
    test "uses exec --json and passes the prompt after --" do
      {:ok, %{args: args}} =
        Codex.build_command(%{@turn | model: "gpt-x", permission_mode: "read-only"})

      assert [
               "exec",
               "--json",
               "-m",
               "gpt-x",
               "-c",
               ~s(sandbox_mode="read-only"),
               "--",
               "--help; rm -rf /"
             ] =
               args
    end

    test "resumes with the thread id" do
      {:ok, %{args: args}} = Codex.build_command(%{@turn | resume: "thread-1"})
      assert ["exec", "resume", "--json", "--", "thread-1", "--help; rm -rf /"] = args
    end

    test "never passes sandbox modes it does not declare" do
      {:ok, %{args: args}} = Codex.build_command(%{@turn | permission_mode: "danger-full-access"})
      refute Enum.any?(args, &String.contains?(&1, "danger"))
    end

    test "reads the listed models from `codex debug models`, by priority" do
      json =
        Jason.encode!(%{
          "models" => [
            %{"slug" => "b", "display_name" => "B", "visibility" => "list", "priority" => 5},
            %{"slug" => "hidden", "visibility" => "hide", "priority" => 1},
            %{
              "slug" => "a",
              "display_name" => "A",
              "description" => "best",
              "visibility" => "list",
              "priority" => 2
            }
          ]
        })

      assert {:ok, [%{id: "a", name: "A", description: "best"}, %{id: "b", name: "B"}]} =
               Codex.parse_model_catalog(json)
    end

    test "returns :error for an unexpected catalog" do
      assert :error = Codex.parse_model_catalog("not json")
      assert :error = Codex.parse_model_catalog(~s({"data": []}))
      assert :error = Codex.parse_model_catalog(~s({"models": []}))
    end

    test "parses JSONL events" do
      assert [{:harness_ref, "t-1"}] =
               Codex.parse_output(:stdout, ~s({"type":"thread.started","thread_id":"t-1"}))

      assert [{:message, :assistant, "Done"}] =
               Codex.parse_output(
                 :stdout,
                 ~s({"type":"item.completed","item":{"type":"agent_message","text":"Done"}})
               )

      assert [{:tool, "shell", "git status"}] =
               Codex.parse_output(
                 :stdout,
                 ~s({"type":"item.started","item":{"type":"command_execution","command":"git status"}})
               )

      assert [{:error, "boom"}] =
               Codex.parse_output(:stdout, ~s({"type":"turn.failed","error":{"message":"boom"}}))

      assert [] = Codex.parse_output(:stdout, ~s({"type":"turn.started"}))

      assert [{:error, "Model metadata not found"}] =
               Codex.parse_output(
                 :stdout,
                 ~s({"type":"item.completed","item":{"type":"error","message":"Model metadata not found"}})
               )
    end
  end

  describe "Fake" do
    test "declares its scenarios as a reliable model list" do
      assert ~w(success stream failure hang audit-pass) -- Fake.capabilities().models == []
    end

    test "parses its line protocol" do
      assert [{:harness_ref, "r"}] = Fake.parse_output(:stdout, "ref r")
      assert [{:message, :assistant, "hi"}] = Fake.parse_output(:stdout, "say hi")
      assert [{:tool, "tool", "x"}] = Fake.parse_output(:stdout, "tool x")
      assert [{:output, "other"}] = Fake.parse_output(:stdout, "other")
    end
  end
end
