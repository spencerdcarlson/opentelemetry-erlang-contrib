defmodule OpentelemetryEctoTest do
  use ExUnit.Case
  import Ecto.Query
  require OpenTelemetry.Tracer

  alias OpentelemetryEcto.TestRepo, as: Repo
  alias OpentelemetryEcto.TestModels.{Comment, User, Post}

  require Ecto.Query, as: Query
  require OpenTelemetry.Tracer, as: Tracer

  @event_name [:opentelemetry_ecto, :test_repo]

  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  setup do
    :application.stop(:opentelemetry)
    :application.set_env(:opentelemetry, :tracer, :otel_tracer_default)

    :application.set_env(:opentelemetry, :processors, [
      {:otel_batch_processor, %{scheduled_delay_ms: 1}}
    ])

    :application.start(:opentelemetry)

    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    OpenTelemetry.Tracer.start_span("test")

    on_exit(fn ->
      OpenTelemetry.Tracer.end_span()
    end)
  end

  test "captures basic query events" do
    attach_handler()

    Repo.all(User)

    assert_receive {:span,
                    span(
                      name: "opentelemetry_ecto.test_repo.query:users",
                      attributes: attributes,
                      kind: :client
                    )}

    assert %{
             "db.connection_string": "ecto://localhost/opentelemetry_ecto_test",
             "db.instance": "opentelemetry_ecto_test",
             "db.name": "opentelemetry_ecto_test",
             "db.sql.table": "users",
             "db.statement": "SELECT u0.\"id\", u0.\"email\" FROM \"users\" AS u0",
             "db.system": "postgresql",
             "db.type": :sql,
             "db.user": "postgres",
             decode_time_microseconds: _,
             "net.peer.name": "localhost",
             "net.transport": "IP.TCP",
             query_time_microseconds: _,
             queue_time_microseconds: _,
             total_time_microseconds: _
           } = :otel_attributes.map(attributes)
  end

  test "changes the time unit" do
    attach_handler(time_unit: :millisecond)

    Repo.all(Post)

    assert_receive {:span,
                    span(
                      name: "opentelemetry_ecto.test_repo.query:posts",
                      attributes: attributes
                    )}

    assert %{
             "db.instance": "opentelemetry_ecto_test",
             "db.statement": "SELECT p0.\"id\", p0.\"body\", p0.\"user_id\" FROM \"posts\" AS p0",
             "db.type": :sql,
             "db.connection_string": "ecto://localhost/opentelemetry_ecto_test",
             decode_time_milliseconds: _,
             query_time_milliseconds: _,
             queue_time_milliseconds: _,
             "db.sql.table": "posts",
             total_time_milliseconds: _
           } = :otel_attributes.map(attributes)
  end

  test "changes the span name prefix" do
    attach_handler(span_prefix: "Ecto")

    Repo.all(User)

    assert_receive {:span, span(name: "Ecto:users")}
  end

  test "collects multiple spans" do
    user = Repo.insert!(%User{email: "opentelemetry@erlang.org"})
    Repo.insert!(%Post{body: "We got traced!", user: user})

    attach_handler()

    User
    |> Repo.all()
    |> Repo.preload([:posts])

    assert_receive {:span, span(name: "opentelemetry_ecto.test_repo.query:users")}
    assert_receive {:span, span(name: "opentelemetry_ecto.test_repo.query:posts")}
  end

  test "sets error message on error" do
    attach_handler()

    try do
      Repo.all(from u in "users", select: u.non_existant_field)
    rescue
      _ -> :ok
    end

    assert_receive {:span,
                    span(
                      name: "opentelemetry_ecto.test_repo.query:users",
                      status: {:status, :error, message}
                    )}

    assert message =~ "non_existant_field does not exist"
  end

  test "preloads in sequence are tied to the parent span" do
    user = Repo.insert!(%User{email: "opentelemetry@erlang.org"})
    Repo.insert!(%Post{body: "We got traced!", user: user})
    Repo.insert!(%Comment{body: "We got traced!", user: user})

    attach_handler()

    Tracer.with_span "parent span" do
      Repo.all(Query.from(User, preload: [:posts, :comments]), in_parallel: false)
    end

    assert_receive {:span, span(span_id: root_span_id, name: "parent span")}
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:users")}
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:posts")}
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:comments")}
  end

  test "preloads in parallel are tied to the parent span" do
    user = Repo.insert!(%User{email: "opentelemetry@erlang.org"})
    Repo.insert!(%Post{body: "We got traced!", user: user})
    Repo.insert!(%Comment{body: "We got traced!", user: user})

    attach_handler()

    Tracer.with_span "parent span" do
      Repo.all(Query.from(User, preload: [:posts, :comments]))
    end

    assert_receive {:span, span(span_id: root_span_id, name: "parent span")}
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:users")}
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:posts")}
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:comments")}
  end

  test "nested query preloads are tied to the parent span" do
    user = Repo.insert!(%User{email: "opentelemetry@erlang.org"})
    Repo.insert!(%Post{body: "We got traced!", user: user})
    Repo.insert!(%Comment{body: "We got traced!", user: user})

    attach_handler()

    Tracer.with_span "parent span" do
      users_query = from u in User, preload: [:posts, :comments]
      comments_query = from c in Comment, preload: [user: ^users_query]
      Repo.all(Query.from(User, preload: [:posts, comments: ^comments_query]))
    end

    assert_receive {:span, span(span_id: root_span_id, name: "parent span")}
    # root query
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:users")}
    # comments preload
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:comments")}
    # users preload
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:users")}
    # preloads of user
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:posts")}
    assert_receive {:span, span(parent_span_id: ^root_span_id, name: "opentelemetry_ecto.test_repo.query:comments")}
  end

  def attach_handler(config \\ []) do
    # For now setup the handler manually in each test
    handler = {__MODULE__, self()}

    :telemetry.attach(handler, @event_name ++ [:query], &OpentelemetryEcto.handle_event/4, config)

    on_exit(fn ->
      :telemetry.detach(handler)
    end)
  end
end
