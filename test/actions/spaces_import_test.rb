# frozen_string_literal: true

require_relative "action_test_helper"
require "zlib"
require "stringio"
require "rubygems/package"
require "tmpdir"

# POST /spaces/import — the frozen I04 contract: bearer/session auth, gzip'd
# tar body, 200 {id, slug, iterations, artifacts, runs}, and the guards
# (64MB → 413, unsafe tar entry → 400 with nothing extracted, bad gzip/tar →
# 400, missing space.yaml → 400).
class SpacesImportTest < Minitest::Test
  include ActionTestHelper

  def setup
    setup_db
    OmniAuth.config.test_mode = true
    @user            = Factory[:user, github_uid: "import-owner", username: "import_owner"]
    @api_tokens_repo = Space::Server::App["repos.api_tokens_repo"]
  end

  def teardown
    OmniAuth.config.mock_auth[:github] = :csrf_detected
  end

  def conn = Space::Server::App["db.gateway"].connection

  def mint_token(user = @user)
    secret, = @api_tokens_repo.create(user_id: user.id, name: "push")
    secret
  end

  # ── fixture bundles ────────────────────────────────────────────────────────

  # A small, realistic space: space.yaml, a brief, and a narrator note.
  def push_bundle(id: "push-fixture-space")
    Dir.mktmpdir("push_fixture") do |dir|
      File.write(File.join(dir, "space.yaml"), <<~YAML)
        id: #{id}
        title: Push Fixture Space
        status: active
        architect:
          status: active
          iterations: []
      YAML
      brief = File.join(dir, "architecture")
      FileUtils.mkdir_p(brief)
      File.write(File.join(brief, "BRIEF.md"), "# Brief\n\npushed bundle fixture\n")
      notes = File.join(dir, "notes")
      FileUtils.mkdir_p(notes)
      File.write(File.join(notes, "narrative-20261014-0100.md"), "# Narrative\n\npushed note\n")

      bundle_dir(dir)
    end
  end

  # Tar + gzip a directory's contents. TarWriter mirrors Linux tar's flat
  # entry names (no AppleDouble/PAX noise from the macOS bsdtar).
  def bundle_dir(dir)
    tar = StringIO.new("".b)
    Gem::Package::TarWriter.new(tar) do |tw|
      Dir[File.join(dir, "**", "*")].sort.each do |path|
        rel = path.delete_prefix("#{dir}/")
        if File.directory?(path)
          tw.mkdir(rel, 0o755)
        else
          tw.add_file(rel, 0o644) { |io| io.write(File.binread(path)) }
        end
      end
    end
    gzip(tar.string)
  end

  def tar_space_with(extra, space_yaml: "id: t\n")
    tar = StringIO.new("".b)
    Gem::Package::TarWriter.new(tar) do |tw|
      tw.add_file("space.yaml", 0o644) { |io| io.write(space_yaml) } if space_yaml
      extra.each do |name, kind|
        case kind
        when :symlink then tw.add_symlink(name, "/etc/passwd", 0o777)
        when :dir     then tw.mkdir(name, 0o755)
        else tw.add_file(name, 0o644) { |io| io.write(kind) }
        end
      end
    end
    gzip(tar.string)
  end

  def gzip(bytes)
    StringIO.open("".b) do |s|
      Zlib::GzipWriter.wrap(s) { |gz| gz.write(bytes) }
      s.string
    end
  end

  # Hand-built ustar headers for the GNU entries Gem::Package::TarWriter cannot
  # emit ("L" long names — split_name raises instead) — deterministic and
  # in-process, with no bsdtar AppleDouble noise. size may exceed the body to
  # model a bomb's declared expansion; the reader tolerates the short final
  # body without reading it, which is exactly what the validate pass must cap.
  def tar_bytes(entries)
    out = +"".b
    entries.each do |(name, opts)|
      body     = opts.fetch(:body, "").to_s.b
      typeflag = opts.fetch(:typeflag, "0")
      out << ustar_header(name, opts.fetch(:size, body.bytesize), typeflag)
      out << body
      out << "\x00" * ((512 - (body.bytesize % 512)) % 512)
    end
    out << "\x00" * 512
  end

  def ustar_header(name, size, typeflag)
    header = +"".b
    header << name.to_s.b.ljust(100, "\x00")
    header << "0000644\x00"
    header << "0000000\x00" # uid
    header << "0000000\x00" # gid
    header << format("%011o", size) << "\x00"
    header << "00000000000\x00" # mtime
    header << "        " # checksum placeholder — summed as spaces
    header << typeflag
    header << "\x00" * 100 # linkname
    header << "ustar\x0000"
    header << "\x00" * 64  # uname + gname (32 + 32)
    header << "\x00" * 16  # devmajor + devminor
    header << "\x00" * 155 # prefix
    header << "\x00" * 12  # padding
    raise "bad header length" unless header.bytesize == 512

    header[148, 8] = format("%06o", header.bytes.sum) + "\x00 "
    header
  end

  # ── happy paths ─────────────────────────────────────────────────────────────

  def test_bearer_happy_path_imports_space
    secret = mint_token

    status, _, body = post_raw(
      "/spaces/import",
      body: tar_space_with(
        [["architecture", :dir],
         ["architecture/BRIEF.md", "# Brief\n\npushed bundle\n"],
         ["README.md", "# hi"]],
        space_yaml: <<~YAML
          id: pushed-space
          title: Pushed Space
          status: active
          architect:
            status: active
            iterations: []
        YAML
      ),
      content_type: "application/gzip",
      bearer: secret
    )

    assert_equal 200, status
    parsed = parse_json(body)
    assert parsed["id"]
    assert_equal "pushed-space", parsed["slug"]
    assert_equal 0, parsed["iterations"]
    assert_equal 1, parsed["artifacts"]
    assert_equal 0, parsed["runs"]
    space = conn[:spaces].where(slug: "pushed-space").first
    assert_equal @user.id, space[:user_id], "imported space must be owned by the token's owner"
  end

  def test_bearer_happy_path_imports_notes_artifact
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import", body: push_bundle, content_type: "application/gzip", bearer: secret
    )
    assert_equal 200, status
    assert_equal 2, parse_json(body)["artifacts"] # brief + narrator note

    note = conn[:artifacts].where(path: "notes/narrative-20261014-0100.md").first
    assert_equal "narrative", note[:kind]
    assert_nil note[:iteration_id]
  end

  def test_session_auth_imports_space
    sign_in(@user)
    status, _, body = post_raw(
      "/spaces/import", body: push_bundle, content_type: "application/gzip"
    )
    assert_equal 200, status
    assert_equal "push-fixture-space", parse_json(body)["slug"]
  end

  def test_repush_is_idempotent
    secret = mint_token
    bundle = push_bundle
    _, _, first = post_raw("/spaces/import", body: bundle, content_type: "application/gzip", bearer: secret)
    _, _, again = post_raw("/spaces/import", body: bundle, content_type: "application/gzip", bearer: secret)

    assert_equal parse_json(first), parse_json(again),
      "re-push must upsert, not duplicate"
    assert_equal 1, conn[:spaces].where(slug: "push-fixture-space").count
    assert_equal 1, conn[:artifacts].where(path: "architecture/BRIEF.md").count,
      "re-push must upsert by path, not duplicate"
  end

  # ── guards ──────────────────────────────────────────────────────────────────

  def test_unauthenticated_returns_401
    status, _, body = post_raw(
      "/spaces/import", body: push_bundle, content_type: "application/gzip"
    )
    assert_equal 401, status
    assert parse_json(body).key?("error")
    assert_equal 0, conn[:spaces].count
  end

  def test_traversal_entry_rejected_with_400_and_nothing_imported
    secret = mint_token
    cwd_files = Dir.children(Dir.pwd)

    status, _, body = post_raw(
      "/spaces/import",
      body: tar_space_with([["../evil.txt", "pwned"]]),
      content_type: "application/gzip",
      bearer: secret
    )

    assert_equal 400, status
    assert_match(/Unsafe tar path/, parse_json(body)["error"])
    assert_equal 0, conn[:spaces].count, "nothing may be imported"
    assert_equal cwd_files, Dir.children(Dir.pwd), "no file may escape the extraction dir"
  end

  def test_symlink_entry_rejected_with_400_and_nothing_imported
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import",
      body: tar_space_with([["link", :symlink]]),
      content_type: "application/gzip",
      bearer: secret
    )

    assert_equal 400, status
    assert_match(/Unsafe tar entry/, parse_json(body)["error"])
    assert_equal 0, conn[:spaces].count
  end

  def test_invalid_gzip_returns_400
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import", body: "definitely not gzip", content_type: "application/gzip", bearer: secret
    )
    assert_equal 400, status
    assert_match(/gzip/, parse_json(body)["error"])
    assert_equal 0, conn[:spaces].count
  end

  def test_invalid_tar_returns_400
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import", body: gzip("not a tar at all" * 100), content_type: "application/gzip", bearer: secret
    )
    assert_equal 400, status
    assert parse_json(body).key?("error")
    assert_equal 0, conn[:spaces].count
  end

  def test_oversize_body_returns_413
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import",
      body: Random.bytes(64 * 1024 * 1024 + 1),
      content_type: "application/gzip",
      bearer: secret
    )
    assert_equal 413, status
    assert parse_json(body).key?("error")
    assert_equal 0, conn[:spaces].count
  end

  def test_missing_space_yaml_returns_400
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import",
      body: tar_space_with([["README.md", "# no space here"]], space_yaml: nil),
      content_type: "application/gzip",
      bearer: secret
    )
    assert_equal 400, status
    assert_match(/space\.yaml/, parse_json(body)["error"])
    assert_equal 0, conn[:spaces].count
  end

  # ── GNU L/K entries and the extracted-bytes cap ──────────────────────────

  def long_note_name = "notes/#{"n" * 140}.md" # 146-char path, unrepresentable in ustar name+

  def test_long_name_via_gnu_l_entry_imports_cleanly
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import",
      body: gzip(tar_bytes([
        ["space.yaml", body: <<~YAML],
          id: pushed-longname
          title: Pushed Longname
          status: active
          architect:
            status: active
            iterations: []
        YAML
        ["notes", typeflag: "5"],
        ["././@LongLink", body: "#{long_note_name}\x00", typeflag: "L"],
        [long_note_name[0, 99], body: "# Long note\n"]
      ])),
      content_type: "application/gzip",
      bearer: secret
    )

    assert_equal 200, status, "long path via L must import (got #{parse_json(body)['error']})"
    note = conn[:artifacts].where(space_id: parse_json(body)["id"], kind: "note").first
    refute_nil note, "the long-named note must be imported"
    assert_equal long_note_name, note[:path], "the resolved (not truncated) name must be stored"
    assert_operator note[:path].length, :>, 100
  end

  def test_traversal_long_name_via_gnu_l_entry_rejected_with_400_and_nothing_imported
    secret = mint_token
    cwd_files = Dir.children(Dir.pwd)

    status, _, body = post_raw(
      "/spaces/import",
      body: gzip(tar_bytes([
        ["space.yaml", body: "id: evil-long\n"],
        ["././@LongLink", body: "../../../../etc/evil\x00", typeflag: "L"],
        ["trunc", body: "pwned"]
      ])),
      content_type: "application/gzip",
      bearer: secret
    )

    assert_equal 400, status
    assert_match(/Unsafe tar path/, parse_json(body)["error"])
    assert_equal 0, conn[:spaces].count, "nothing may be imported"
    assert_equal cwd_files, Dir.children(Dir.pwd), "no file may escape the extraction dir"
  end

  def test_gnu_k_entry_is_tolerated
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import",
      body: gzip(tar_bytes([
        ["space.yaml", body: "id: pushed-klink\n"],
        ["././@LongLink", body: "somewhere/else\x00", typeflag: "K"],
        ["README.md", body: "# fine\n"]
      ])),
      content_type: "application/gzip",
      bearer: secret
    )

    assert_equal 200, status, "a K entry alone must not fail the bundle"
    assert_equal "pushed-klink", parse_json(body)["slug"]
  end

  def test_bundle_declaring_expansion_past_the_cap_rejected_with_400_and_nothing_imported
    secret = mint_token
    status, _, body = post_raw(
      "/spaces/import",
      body: gzip(tar_bytes([
        ["space.yaml", body: "id: pushed-bomb\n"],
        ["bomb.bin", size: 256 * 1024 * 1024 + 1]
      ])),
      content_type: "application/gzip",
      bearer: secret
    )

    assert_equal 400, status
    assert_match(/256|unpacks/, parse_json(body)["error"])
    assert_equal 0, conn[:spaces].count, "nothing may be imported"
    assert_equal 0, conn[:artifacts].count, "no partial import"
  end
end
