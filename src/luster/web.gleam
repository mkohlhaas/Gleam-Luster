import gleam/bit_array
import gleam/bytes_builder
import gleam/erlang
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/iterator
import gleam/string
import gleam/uri
import luster/line_poker/computer_player
import luster/line_poker/game as g
import luster/line_poker/session
import luster/line_poker/store
import luster/pubsub
import luster/web/home/view as tea_home
import luster/web/layout
import luster/web/line_poker/socket
import luster/web/line_poker/view as tea_game
import mist
import nakai
import nakai/html

pub fn router(
  request: request.Request(mist.Connection),
  store: session.Registry,
  pubsub: pubsub.PubSub(Int, socket.Message),
) -> response.Response(mist.ResponseData) {
  case request.method, request.path_segments(request) {
    http.Get, [] -> {
      tea_home.init(store)
      |> tea_home.view()
      |> render(with: fn(body) { layout.view("", False, body) })
    }

    http.Post, ["battleline"] -> {
      request
      |> process_form()
      |> create_games(store, pubsub)

      redirect("/")
    }

    http.Get, ["battleline", session_id] -> {
      let assert Ok(id) = int.parse(session_id)

      case session.get_session(store, id) {
        Ok(subject) -> {
          let record = session.get_record(subject)
          tea_game.init(record.gamestate)
          |> tea_game.view()
          |> render(with: fn(body) { layout.view(session_id, True, body) })
        }

        Error(Nil) -> {
          case store.get(id) {
            Ok(record) ->
              html.UnsafeInlineHtml(record.document)
              |> render(with: fn(body) { layout.view(session_id, False, body) })

            Error(Nil) -> redirect("/")
          }
        }
      }
    }

    http.Get, ["events", session_id] -> {
      let assert Ok(id) = int.parse(session_id)

      case session.get_session(store, id) {
        Ok(subject) -> socket.start(request, subject, pubsub)
        Error(Nil) -> not_found()
      }
    }

    http.Get, ["assets", ..] -> {
      serve_assets(request)
    }

    _, _ -> {
      not_found()
    }
  }
}

fn create_games(
  params: List(#(String, String)),
  store: session.Registry,
  pubsub: pubsub.PubSub(Int, socket.Message),
) {
  let #(quantity, rest) = case params {
    [#("quantity", qty), ..rest] ->
      case int.parse(qty) {
        Ok(qty) -> #(qty, rest)
        Error(_) -> #(1, rest)
      }
    _other -> #(1, [])
  }

  let game_mode = case rest {
    [#("PlayerVsPlayer", _)] -> fn(_) {
      let assert Ok(_) = session.new_session(store)
      Nil
    }
    [#("PlayerVsComp", _)] -> fn(_) {
      let assert Ok(subject) = session.new_session(store)
      let assert Ok(_comp_2) = computer_player.start(g.Player2, subject, pubsub)
      Nil
    }
    [#("CompVsComp", _)] | _other -> fn(_) {
      let assert Ok(subject) = session.new_session(store)
      let assert Ok(_comp_1) = computer_player.start(g.Player1, subject, pubsub)
      let assert Ok(_comp_2) = computer_player.start(g.Player2, subject, pubsub)
      Nil
    }
  }

  iterator.range(from: 1, to: quantity)
  |> iterator.each(game_mode)
}

// https://www.iana.org/assignments/media-types/media-types.xhtml
type MIME {
  HTML
  CSS
  JavaScript
  Favicon
  TextPlain
}

fn render(
  body: html.Node(a),
  with layout: fn(html.Node(a)) -> html.Node(a),
) -> response.Response(mist.ResponseData) {
  let document =
    layout(body)
    |> nakai.to_string_builder()
    |> bytes_builder.from_string_builder()
    |> mist.Bytes

  response.new(200)
  |> response.prepend_header("cache-control", "no-store, no-cache, max-age=0")
  |> response.prepend_header("content-type", content_type(HTML))
  |> response.set_body(document)
}

fn redirect(path: String) -> response.Response(mist.ResponseData) {
  response.new(303)
  |> response.prepend_header("cache-control", "no-store, no-cache, max-age=0")
  |> response.prepend_header("location", path)
  |> response.set_body(mist.Bytes(bytes_builder.new()))
}

fn not_found() -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.prepend_header("cache-control", "no-store, no-cache, max-age=0")
  |> response.prepend_header("content-type", content_type(TextPlain))
  |> response.set_body(mist.Bytes(bytes_builder.from_string("Not found")))
}

fn serve_assets(
  request: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let assert Ok(root) = erlang.priv_directory("luster")
  let asset = string.join([root, request.path], "")

  case read_file(asset) {
    Ok(asset) -> {
      let mime = extract_mime(request.path)

      response.new(200)
      |> response.prepend_header("content-type", content_type(mime))
      |> response.set_body(mist.Bytes(asset))
    }

    _ -> {
      not_found()
    }
  }
}

fn process_form(
  request: request.Request(mist.Connection),
) -> List(#(String, String)) {
  let assert Ok(request) = mist.read_body(request, 10_000)
  let assert Ok(value) = bit_array.to_string(request.body)
  let assert Ok(params) = uri.parse_query(value)
  params
}

fn content_type(mime: MIME) -> String {
  case mime {
    HTML -> "text/html; charset=utf-8"
    CSS -> "text/css"
    JavaScript -> "text/javascript"
    Favicon -> "image/x-icon"
    TextPlain -> "text/plain; charset=utf-8"
  }
}

fn extract_mime(path: String) -> MIME {
  let ext =
    path
    |> string.lowercase()
    |> extension()

  case ext {
    ".css" -> CSS
    ".ico" -> Favicon
    ".js" -> JavaScript
    _ -> panic as "unable to identify media type"
  }
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(bytes_builder.BytesBuilder, error)

@external(erlang, "filename", "extension")
fn extension(path: String) -> String
