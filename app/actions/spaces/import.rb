# frozen_string_literal: true

require "zlib"
require "stringio"
require "rubygems/package"
require "fileutils"
require "tmpdir"

module Space
  module Server
    module Actions
      module Spaces
        # POST /spaces/import — authenticated HTTP mouth for a pushed space
        # bundle (frozen contract, I04):
        #
        #   body:    gzip'd tar stream, Content-Type application/gzip
        #   auth:    Bearer token (the I03 token_user path) or session
        #   success: 200 {id:, slug:, iterations:, artifacts:, runs:}
        #   guards:  body over 64MB → 413; tar entry with an absolute path,
        #            a ".." component, or a non-file/dir type (symlinks,
        #            links, devices) → 400 with nothing extracted; GNU L
        #            long names resolved and guarded, K tolerated; total
        #            extracted bytes capped at 256MB; invalid gzip/tar → 400;
        #            extracted root missing space.yaml → 400
        #
        # Re-pushes are idempotent — SpaceImporter upserts by slug and by
        # artifact path. The bundle is extracted into a fresh tmpdir and
        # removed after import; the space persists the "pushed" source marker,
        # never the ephemeral tmpdir path.
        class Import < Space::Server::Action
          # Frozen contract: 413 above this. Checked against the declared
          # Content-Length first, then enforced while streaming rack.input.
          MAX_BODY_BYTES = 64 * 1024 * 1024
          CHUNK_BYTES    = 1024 * 1024

          class BodyTooLarge < StandardError; end
          class BundleError  < StandardError; end

          include Space::Server::Deps[
            "repos.spaces_repo",
            "repos.iterations_repo",
            "repos.artifacts_repo",
            "repos.runs_repo",
            "repos.conversations_repo",
            "repos.messages_repo"
          ]

          def handle(req, res)
            user = authenticated_user(req)
            unless user
              res.content_type = JSON_CONTENT_TYPE
              halt 401, JSON.generate(error: "Sign in required.")
            end

            space = begin
              bundle = Bundle.new(inflate(read_body(req)))
              bundle.validate!
              import_bundle(bundle, user)
            rescue BodyTooLarge
              res.content_type = JSON_CONTENT_TYPE
              halt 413, JSON.generate(error: "Request body exceeds 64MB.")
            rescue BundleError => e
              res.content_type = JSON_CONTENT_TYPE
              halt 400, JSON.generate(error: e.message)
            end

            render_json(res, {
              id:         space.id,
              slug:       space.slug,
              iterations: iterations_repo.count_for_space(space.id),
              artifacts:  artifacts_repo.count_for_space(space.id),
              runs:       runs_repo.count_for_space(space.id)
            })
          end

          private

          # Never reads rack.input unboundedly: the declared Content-Length is
          # rejected up front, and a lying/undeclared body still cannot grow
          # past MAX_BODY_BYTES in memory — falcon hands us rack.input, we
          # stream it in chunks and stop at the cap.
          def read_body(req)
            raise BodyTooLarge if req.env["CONTENT_LENGTH"].to_i > MAX_BODY_BYTES

            io  = req.env["rack.input"]
            buf = +""
            while (chunk = io.read(CHUNK_BYTES))
              buf << chunk
              raise BodyTooLarge if buf.bytesize > MAX_BODY_BYTES
            end
            buf
          end

          def inflate(body)
            Zlib::GzipReader.wrap(StringIO.new(body), &:read)
          rescue Zlib::Error
            raise BundleError, "Not a valid gzip stream."
          end

          def import_bundle(bundle, user)
            Dir.mktmpdir("space-import") do |root|
              bundle.extract_to(root)

              unless File.file?(File.join(root, "space.yaml"))
                raise BundleError, "Bundle is missing space.yaml."
              end

              importer.import!(root, user: user, pushed: true)
            end
          end

          def importer
            # Actions are frozen singleton objects — no instance memoization.
            Space::Server::SpaceImporter.new(
              spaces_repo:        spaces_repo,
              iterations_repo:    iterations_repo,
              artifacts_repo:     artifacts_repo,
              runs_repo:          runs_repo,
              conversations_repo: conversations_repo,
              messages_repo:      messages_repo
            )
          end

          # Machine pushes (bearer) carry no session cookie — same carve-out as
          # the runs ingest endpoints; browser/session requests keep CSRF.
          def verify_csrf_token?(req, *)
            bearer_request?(req) ? false : super
          end

          # Validates then extracts a tar bundle. Nothing is written to disk
          # until every entry header has passed the guards — so a single unsafe
          # entry means nothing was extracted. The extracted tree can never
          # escape its directory: absolute paths and ".." components are
          # rejected, and only regular files and directories are written.
          class Bundle
            # typeflags this reader accepts: regular file, directory, the GNU
            # long-name/long-link modifiers ("L"/"K"), and the PAX/global
            # metadata headers (no filesystem effect). Symlinks ("2"),
            # hardlinks ("1"), devices, fifos — everything else — is rejected
            # as unsafe.
            ALLOWED_TYPES = %w[0 \x00 5 x g L K].freeze
            SKIP_TYPES    = %w[x g L K].freeze
            GNU_LONG_NAME = "L"

            # Frozen cap on total bytes written across all entries. Enforced on
            # both passes: validate! sums the declared header sizes (nothing
            # may pass validation that unpacks past the cap) and extract_to
            # re-checks the bytes actually written.
            MAX_EXTRACTED_BYTES = 256 * 1024 * 1024

            def self.extracted_bytes_error
              "Bundle unpacks past #{MAX_EXTRACTED_BYTES} extracted bytes."
            end

            def initialize(tar_bytes)
              @tar = StringIO.new(tar_bytes)
            end

            # Header pass: every entry must pass the guards before pass two
            # may write anything. The extracted-bytes cap is decided here from
            # the declared sizes, so a bomb never reaches the extract pass.
            def validate!
              unpacked = 0
              each_resolved_entry do |entry, _|
                unpacked += entry.header.size
                raise BundleError, self.class.extracted_bytes_error if unpacked > MAX_EXTRACTED_BYTES
              end
            end

            def extract_to(dir)
              written = 0
              each_resolved_entry do |entry, name|
                if entry.directory?
                  FileUtils.mkdir_p(File.join(dir, name))
                  next
                end

                content = entry.read
                written += content.bytesize
                raise BundleError, self.class.extracted_bytes_error if written > MAX_EXTRACTED_BYTES

                File.binwrite(File.join(dir, name), content)
              end
            end

            private

            def each_entry
              Gem::Package::TarReader.new(@tar) { |reader| reader.each_entry { |entry| yield entry } }
              @tar.rewind
            rescue Gem::Package::TarInvalidError, ArgumentError, RangeError, EOFError
              raise BundleError, "Not a valid tar stream."
            end

            # Walks entries applying the GNU long-name rule: an "L" entry's
            # content names the NEXT entry (the reader does not resolve it for
            # us), so every yielded name is the resolved one — and the one the
            # traversal guard sees. "K" (long-link target) is accepted and
            # discarded: links are never extracted. The type guard runs here so
            # both passes reject unsafe entries identically.
            def each_resolved_entry
              long_name = nil
              each_entry do |entry|
                type = entry.header.typeflag
                unless ALLOWED_TYPES.include?(type)
                  raise BundleError, "Unsafe tar entry #{entry.full_name.inspect} (type #{type.inspect})"
                end
                long_name = entry.read.unpack1("Z*") if type == GNU_LONG_NAME
                next if SKIP_TYPES.include?(type)

                name = long_name || entry.full_name
                long_name = nil
                raise BundleError, "Unsafe tar path #{name.inspect}" unless safe_name?(name)

                yield entry, name
              end
            end

            def safe_name?(name)
              return false if name.empty? || name.start_with?("/")

              !name.split("/").include?("..")
            end
          end
        end
      end
    end
  end
end
