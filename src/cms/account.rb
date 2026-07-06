require "openssl"
require "securerandom"

require_relative "storage"
require_relative "validation"

module Cms
  module Account
    COLLECTION_FILE = "accounts.json"

    # PBKDF2-HMAC-SHA256 — a built-in, salted, slow KDF (OpenSSL ships with every
    # standard Ruby). The stored string is self describing (algo, digest,
    # iterations, salt, hash) so a future cost bump can verify old hashes.
    ITERATIONS = 210_000
    KEY_LENGTH = 32
    DIGEST = "sha256"

    def self.hash_password(password)
      salt = SecureRandom.bytes(16)
      derived = OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: ITERATIONS, length: KEY_LENGTH, hash: DIGEST)
      "pbkdf2$#{DIGEST}$#{ITERATIONS}$#{salt.unpack1("H*")}$#{derived.unpack1("H*")}"
    end

    def self.secure_compare(a, b)
      return false unless a.bytesize == b.bytesize
      left = a.unpack("C*")
      result = 0
      b.each_byte.with_index { |byte, i| result |= byte ^ left[i] }
      result == 0
    end

    def self.verify_password(password, stored)
      return false unless stored.is_a?(String)
      parts = stored.split("$")
      return false if parts.length != 5 || parts[0] != "pbkdf2"
      _, digest, iterations_raw, salt_hex, hash_hex = parts
      begin
        iterations = Integer(iterations_raw, 10)
      rescue ArgumentError
        return false
      end
      return false if iterations < 1
      salt = [salt_hex].pack("H*")
      expected = [hash_hex].pack("H*")
      actual = OpenSSL::KDF.pbkdf2_hmac(password, salt: salt, iterations: iterations, length: expected.bytesize, hash: digest)
      secure_compare(expected, actual)
    end

    def self.find_by_username(username)
      Cms::Storage.read_collection(COLLECTION_FILE).find { |a| a["username"] == username }
    end

    def self.find_by_id(account_id)
      Cms::Storage.read_collection(COLLECTION_FILE).find { |a| a["id"] == account_id }
    end

    # A dummy hash kept so an unknown username still runs one PBKDF2 verification:
    # the response time does not reveal whether the username existed.
    DUMMY_HASH = hash_password(SecureRandom.hex(16))

    def self.authenticate(username, password)
      account = find_by_username(username)
      ok = verify_password(password, account ? account["passwordHash"] : DUMMY_HASH)
      ok && account ? account : nil
    end

    def self.create_account(username, password, role)
      Cms::Storage.with_lock do
        accounts = Cms::Storage.read_collection(COLLECTION_FILE)
        raise "Account already exists: #{username}" if accounts.any? { |a| a["username"] == username }
        account = { "id" => Cms::Validation.generate_uuid, "username" => username, "passwordHash" => hash_password(password), "role" => role }
        accounts << account
        Cms::Storage.write_collection(COLLECTION_FILE, accounts)
        account
      end
    end

    # Bootstrap: with an empty store and ADMIN_USER/ADMIN_PASSWORD set, the first
    # start creates a single admin. Idempotent — a populated store is a no-op, and
    # missing env vars leave the store empty (every protected write then 401s).
    def self.seed_admin
      Cms::Storage.with_lock do
        user = ENV["ADMIN_USER"]
        password = ENV["ADMIN_PASSWORD"]
        return nil if user.nil? || user.empty? || password.nil? || password.empty?
        accounts = Cms::Storage.read_collection(COLLECTION_FILE)
        return nil unless accounts.empty?
        account = { "id" => Cms::Validation.generate_uuid, "username" => user, "passwordHash" => hash_password(password), "role" => "admin" }
        Cms::Storage.write_collection(COLLECTION_FILE, [account])
        account
      end
    end
  end
end
