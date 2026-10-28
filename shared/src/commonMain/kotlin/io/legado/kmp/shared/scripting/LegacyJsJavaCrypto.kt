package io.legado.kmp.shared.scripting

internal val LEGACY_JS_JAVA_CRYPTO = """
    var secretKeys = new WeakMap();
    var secretKeyGet = Function.prototype.call.bind(WeakMap.prototype.get, secretKeys);
    var secretKeySet = Function.prototype.call.bind(WeakMap.prototype.set, secretKeys);
    function JSecretKeySpec(bytes, offset, length, algorithm) {
      if (arguments.length !== 2 && arguments.length !== 4) throw new fail('Unsupported SecretKeySpec overload');
      algorithm = arguments.length === 2 ? offset : algorithm;
      if (bytes == null || algorithm == null) throw new fail('IllegalArgumentException: missing SecretKeySpec argument');
      bytes = byteArray(bytes);
      if (!bytes.length) throw new fail('IllegalArgumentException: empty SecretKeySpec key');
      if (arguments.length === 4) {
        offset = index(offset, bytes.length, true);
        length = index(length, bytes.length - offset, true);
        bytes = slice(bytes, offset, offset + length);
      }
      algorithm = text(algorithm);
      var target = create(JSecretKeySpec.prototype);
      secretKeySet(target, { bytes: bytes, algorithm: algorithm });
      method(target, 'getEncoded', function() { arity(arguments, 0, 0, 'SecretKeySpec.getEncoded'); return slice(bytes); });
      method(target, 'getAlgorithm', function() { arity(arguments, 0, 0, 'SecretKeySpec.getAlgorithm'); return algorithm; });
      method(target, 'getFormat', function() { arity(arguments, 0, 0, 'SecretKeySpec.getFormat'); return 'RAW'; });
      return target;
    }
    JSecretKeySpec.prototype = create(null);

    function macAlgorithm(value) {
      var name = upper(text(value));
      if (name === 'HMACMD5') return { digest: 'MD5', length: 16 };
      if (name === 'HMACSHA1') return { digest: 'SHA1', length: 20 };
      if (name === 'HMACSHA256') return { digest: 'SHA256', length: 32 };
      if (name === 'HMACSHA512') return { digest: 'SHA512', length: 64 };
      throw new fail('NoSuchAlgorithmException: unsupported Mac algorithm ' + text(value));
    }
    function JMac() { throw new fail('Mac must be created with Mac.getInstance'); }
    JMac.prototype = create(null);
    JMac.getInstance = function(algorithm) {
      arity(arguments, 1, 1, 'Mac.getInstance');
      algorithm = text(algorithm);
      var spec = macAlgorithm(algorithm), key = null, pending = [];
      var target = create(JMac.prototype);
      function initialized() {
        if (key === null) throw new fail('IllegalStateException: MAC not initialized');
      }
      function append(bytes) {
        for (var i = 0; i < bytes.length; i++) pending[pending.length] = bytes[i];
      }
      function finish() {
        var result = byteArray(javaHmacBytes(spec.digest, stringify(key), stringify(pending)));
        pending = [];
        return result;
      }
      function storeOutput(output, offset, result) {
        'use strict';
        for (var i = 0; i < result.length; i++) output.items[offset + i] = result[i];
      }
      method(target, 'getAlgorithm', function() { arity(arguments, 0, 0, 'Mac.getAlgorithm'); return algorithm; });
      method(target, 'getMacLength', function() { arity(arguments, 0, 0, 'Mac.getMacLength'); return spec.length; });
      method(target, 'init', function(value, parameters) {
        arity(arguments, 1, 2, 'Mac.init');
        if (arguments.length === 2 && parameters !== null) throw new fail('InvalidAlgorithmParameterException: Mac parameters unsupported');
        var material = value !== null && typeof value === 'object' ? secretKeyGet(value) : null;
        if (!material) throw new fail('InvalidKeyException: Mac.init requires a supported SecretKeySpec');
        key = slice(material.bytes); pending = [];
      });
      method(target, 'update', function(value, offset, length) {
        if (arguments.length !== 1 && arguments.length !== 3) throw new fail('Unsupported Mac.update overload');
        initialized();
        if (value === null) return;
        var raw = unbox(value), bytes;
        if (arguments.length === 1 && typeof raw === 'number') bytes = byteArray([raw]);
        else {
          bytes = byteArray(value);
          if (arguments.length === 3) {
            offset = index(offset, bytes.length, true);
            length = index(length, bytes.length - offset, true);
            bytes = slice(bytes, offset, offset + length);
          }
        }
        append(bytes);
      });
      method(target, 'doFinal', function(value, offset) {
        arity(arguments, 0, 2, 'Mac.doFinal'); initialized();
        if (arguments.length === 2) {
          if (value === null) throw new fail('ShortBufferException: missing Mac output buffer');
          var output = byteSource(value);
          if (!output) throw new fail('Expected a Mac output byte array');
          copyBytes(output);
          offset = unbox(offset);
          if (typeof offset !== 'number' || !integer(offset) || offset < -2147483648 || offset > 2147483647) {
            throw new outOfBounds('Mac output offset must be a Java int');
          }
          if (((output.length - offset) | 0) < spec.length) throw new fail('ShortBufferException: Mac output buffer too small');
          // Java checks capacity with int arithmetic, finishes/resets, then arraycopy checks a negative offset.
          var result = finish();
          if (offset < 0) throw new outOfBounds('Mac output offset out of bounds');
          storeOutput(output, offset, result);
          return;
        }
        if (arguments.length === 1 && value !== null) append(byteArray(value));
        return finish();
      });
      method(target, 'reset', function() { arity(arguments, 0, 0, 'Mac.reset'); pending = []; });
      return target;
    };

    var JDatatypeConverter = staticClass({
      printHexBinary: function(value) {
        arity(arguments, 1, 1, 'DatatypeConverter.printHexBinary');
        var bytes = byteArray(value), alphabet = '0123456789ABCDEF', output = '';
        for (var i = 0; i < bytes.length; i++) output += charAt(alphabet, bytes[i] >>> 4) + charAt(alphabet, bytes[i] & 15);
        return JString(output);
      },
      parseHexBinary: function(value) {
        arity(arguments, 1, 1, 'DatatypeConverter.parseHexBinary');
        value = text(value);
        if (value.length % 2) throw new fail('IllegalArgumentException: odd hex binary length');
        var output = [];
        for (var i = 0; i < value.length; i += 2) {
          var high = stringIndex('0123456789ABCDEF', upper(charAt(value, i)));
          var low = stringIndex('0123456789ABCDEF', upper(charAt(value, i + 1)));
          if (high < 0 || low < 0) throw new fail('IllegalArgumentException: invalid hex binary character');
          output[output.length] = (high << 4) | low;
        }
        return output;
      },
      printBase64Binary: function(value) {
        arity(arguments, 1, 1, 'DatatypeConverter.printBase64Binary');
        return JString(base64Text(value, false, true, 0, '', false));
      },
      parseBase64Binary: function(value) {
        arity(arguments, 1, 1, 'DatatypeConverter.parseBase64Binary');
        return decode64(text(value), false, true, false);
      }
    });
""".trimIndent()
