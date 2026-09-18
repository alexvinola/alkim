defmodule Khymeia.Harness.AdaptersTest do
  use ExUnit.Case, async: true

  alias Khymeia.Harness
  alias Khymeia.Harness.{Capabilities, Claude, Codex, Fake}

  @turn %{
    prompt: "--help; rm -rf /",
    workspace: "/tmp/ws",
    executable: "/usr/local/bin/tool",
    model: nil,
    permission_mode: nil,
    resume: nil
  }

  test "every adapter implements Khymeia.Harness and builds plain argv" do
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

    test "adds model, permission mode and resume only when given" do
      turn = %{@turn | model: "opus", permission_mode: "plan", resume: "abc"}
      {:ok, %{args: args}} = Claude.build_command(turn)

      assert ["--model", "opus"] == Enum.slice(args, 4, 2)
      assert "--permission-mode" in args and "plan" in args
      assert ["--resume", "abc", "--", _] = Enum.take(args, -4)
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
