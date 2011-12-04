# Bitcoin Utils and Network Protocol in Ruby.

require 'digest/sha2'
require 'digest/rmd160'
require 'openssl'

$:.unshift( File.dirname(__FILE__) )


module Bitcoin

  autoload :Connection, 'bitcoin/connection'
  autoload :Protocol,   'bitcoin/protocol'
  autoload :Script,     'bitcoin/script'
  autoload :VERSION,    'bitcoin/version'
  autoload :Network,    'bitcoin/network'
  autoload :Storage,    'bitcoin/storage'
  autoload :Logger,     'bitcoin/logger'

  module Util

    def hth(h); h.unpack("H*")[0]; end
    def htb(h); [h].pack("H*"); end

    def pretty_hex(hex)
      out = ''
      0.upto(hex.size/2).each do |i|
        out << "#{hex[(i*2)..(i*2+1)]} "
      end
      out.strip
    end

    def address_version
      Bitcoin::network[:address_version]
    end

    # hash160 is a 20 bytes (160bits) rmd610-sha256 hexdigest.
    def hash160(hex)
      bytes = [hex].pack("H*")
      Digest::RMD160.hexdigest Digest::SHA256.digest(bytes)
    end

    # checksum is a 4 bytes sha256-sha256 hexdigest.
    def checksum(hex)
      b = [hex].pack("H*") # unpack hex
      Digest::SHA256.hexdigest( Digest::SHA256.digest(b) )[0...8]
    end

    def address_checksum?(address)
      a = base58_to_int(address).to_s(16)
      if address_version == "00"
        Bitcoin.checksum( address_version + a[0...40] ) == a[-8..-1]
      else
        Bitcoin.checksum( a[0...42] ) == a[-8..-1]
      end
    end

    def valid_address?(address) # TODO
      if address_version == "00"
        return false if address[0] != "1"
      else
        a = base58_to_int(address).to_s(16)
        return false if a[0..1] != address_version
      end
      return false if !address_checksum?(address)
      true
    end

    def hash160_from_address(address)
      return nil  unless address_checksum?(address)
      a = base58_to_int(address).to_s(16)
      address_version == "00" ? a[0...40] : a[2...42]
    end

    def sha256(hex)
      Digest::SHA256.hexdigest([hex].pack("H*"))
    end

    def hash160_to_address(hex)
      hex = address_version + hex
      addr = encode_base58(hex + checksum(hex))
      addr = "1" + addr  if address_version == "00"
      addr
    end

    def pubkey_to_address(pubkey)
      hash160_to_address( hash160(pubkey) )
    end

    def encode_base58(hex)
      int_to_base58( hex[0...64].to_i(16) )
    end

    def int_to_base58(int_val)
      alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
      base58_val, base = '', alpha.size
      while(int_val >= base)
        mod = int_val % base
        base58_val = alpha[mod,1] + base58_val
        int_val = (int_val - mod)/base
      end
      alpha[int_val,1] + base58_val
    end

    def base58_to_int(base58_val)
      alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
      int_val, base = 0, alpha.size
      base58_val.reverse.each_char.with_index do |char,index|
        raise ArgumentError, 'Value not a valid Base58 String.' unless char_index = alpha.index(char)
        int_val += char_index*(base**index)
      end
      int_val
    end

    # target compact bits (int) to bignum hex
    def decode_compact_bits(bits)
      bytes = Array.new(size=((bits >> 24) & 255), 0)
      bytes[0] = (bits >> 16) & 255 if size >= 1
      bytes[1] = (bits >>  8) & 255 if size >= 2
      bytes[2] = (bits      ) & 255 if size >= 3
      bytes.map{|i| "%02x" % [i] }.join.rjust(64, '0')
    end

    # target bignum hex to compact bits (int)
    def encode_compact_bits(target)
      # bignum to bytes (bn2mpi) without OpenSSL::BN
      mpi   = [ target.to_i(16).to_s(16) ].pack("H*").unpack("C*")
      bytes = [ mpi.size+1, 0 ].pack("NC").unpack("C*") + mpi

      size = bytes.size - 4
      nbits = size << 24
      nbits |= (bytes[4] << 16) if size >= 1
      nbits |= (bytes[5] <<  8) if size >= 2
      nbits |= (bytes[6]      ) if size >= 3
      nbits
    end

    def decode_target(target_bits)
      case target_bits
      when Fixnum
        [ decode_compact_bits(target_bits).to_i(16), target_bits ]
      when String
        [ target_bits.to_i(16), encode_compact_bits(target_bits) ]
      end
    end

    def bitcoin_elliptic_curve
      ::OpenSSL::PKey::EC.new("secp256k1")
    end

    def generate_key
      key = bitcoin_elliptic_curve.generate_key
      inspect_key( key )
    end

    def inspect_key(key)
      [ key.private_key.to_hex.rjust(64, '0'),
        key.public_key.to_hex.rjust(130, '0') ]
    end

    def generate_address
      prvkey, pubkey = generate_key
      [ pubkey_to_address(pubkey), prvkey, pubkey, hash160(pubkey) ]
    end

    def bitcoin_hash(hex)
      Digest::SHA256.digest(
        Digest::SHA256.digest( [hex].pack("H*").reverse )
      ).reverse.unpack("H*")[0]
    end

    def bitcoin_mrkl(a, b); bitcoin_hash(b + a); end

    def block_hash(prev_block, mrkl_root, time, bits, nonce, ver)
      h = "%08x%08x%08x%064s%064s%08x" %
            [nonce, bits, time, mrkl_root, prev_block, ver]
      bitcoin_hash(h)
    end

    def hash_mrkl_tree(tx)
      chunks = [ tx.dup ]
      while chunks.last.size >= 2
        chunks << chunks.last.each_slice(2).map{|i|
          Bitcoin.bitcoin_mrkl( i[0], i[1] || i[0] )
        }
      end
      chunks.flatten
    end


    def sign_data(key, data)
      key.dsa_sign_asn1(data)
    end

    def verify_signature(hash, signature, public_key)
      key  = bitcoin_elliptic_curve
      key.public_key = ::OpenSSL::PKey::EC::Point.from_hex(key.group, public_key)
      key.dsa_verify_asn1(hash, signature)
    end 

    def open_key(private_key, public_key)
      key  = bitcoin_elliptic_curve
      key.private_key = ::OpenSSL::BN.from_hex(private_key)
      key.public_key  = ::OpenSSL::PKey::EC::Point.from_hex(key.group, public_key)
      key
    end
  end

  module ::OpenSSL
    class BN
      def self.from_hex(hex); new(hex, 16); end
      def to_hex; to_i.to_s(16); end
      def to_mpi; to_s(0).unpack("C*"); end
    end
    class PKey::EC::Point
      def self.from_hex(group, hex)
        new(group, BN.from_hex(hex))
      end
      def to_hex; to_bn.to_hex; end
      def self.bn2mpi(hex) BN.from_hex(hex).to_mpi; end
    end
  end

  extend Util

  @network = :bitcoin

  def self.network
    NETWORKS[@network]
  end

  def self.network= name
    @network = name.to_sym
  end
    
  NETWORKS = {
    :bitcoin => {
      :magic_head => "\xF9\xBE\xB4\xD9",
      :address_version => "00",
      :default_port => 8333,
      :dns_seeds => ["bitseed.xf2.org", "bitseed.bitcoin.org.uk" ],
      :genesis_hash => "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
      :genesis_block => Protocol::Block.new(htb("0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c0101000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000")),
    },
    :testnet => {
      :magic_head => "\xFA\xBF\xB5\xDA",
      :address_version => "6f",
      :default_port => 18333,
      :dns_seeds => [],

      :genesis_hash => "00000007199508e34a9ff81e6ec0c477a4cccff2a4767a8eee39c11db367b008",
      :genesis_block => Protocol::Block.new(htb("0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4adae5494df8ff071dff0bec160101000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000")),

    }
  }
  

end