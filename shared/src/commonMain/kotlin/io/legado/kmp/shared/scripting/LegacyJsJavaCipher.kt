package io.legado.kmp.shared.scripting

internal val LEGACY_JS_JAVA_CIPHER = """
    var javaCipherConfig = __legacyJavaCipherConfig;
    var javaCipherInit = __legacyJavaCipherInit;
    var javaCipherProcess = __legacyJavaCipherProcess;
    var cipherIVs = new WeakMap();
    var cipherIVGet = Function.prototype.call.bind(WeakMap.prototype.get, cipherIVs);
    var cipherIVSet = Function.prototype.call.bind(WeakMap.prototype.set, cipherIVs);

    function cipherInt(value, name) {
      value = unbox(value);
      if (typeof value !== 'number' || !integer(value) || value < 0 || value > 2147483647) {
        throw new outOfBounds(name + ' must be a non-negative Java int');
      }
      return value;
    }
    function cipherCopy(bytes, from, to) {
      var output = [];
      from = from === undefined ? 0 : from;
      to = to === undefined ? bytes.length : to;
      for (var i = from; i < to; i++) field(output, i - from, bytes[i]);
      return output;
    }
    // Do not let an inherited Array.toJSON or Array species expose private key/IV material.
    function cipherBytesJson(bytes) {
      if (bytes === null) return null;
      var output = '[';
      for (var i = 0; i < bytes.length; i++) output += (i ? ',' : '') + numberString(bytes[i], 10);
      return output + ']';
    }
    function cipherRange(value, offset, length) {
      var bytes = byteArray(value);
      offset = cipherInt(offset, 'Cipher input offset');
      length = cipherInt(length, 'Cipher input length');
      if (offset > bytes.length || length > bytes.length - offset) {
        throw new outOfBounds('Cipher input range out of bounds');
      }
      return cipherCopy(bytes, offset, offset + length);
    }
    function JIvParameterSpec(value, offset, length) {
      if (arguments.length !== 1 && arguments.length !== 3) throw new fail('Unsupported IvParameterSpec overload');
      var bytes = arguments.length === 1 ? byteArray(value) : cipherRange(value, offset, length);
      var target = create(JIvParameterSpec.prototype);
      cipherIVSet(target, bytes);
      method(target, 'getIV', function() {
        arity(arguments, 0, 0, 'IvParameterSpec.getIV');
        return cipherCopy(bytes);
      });
      return target;
    }
    JIvParameterSpec.prototype = create(null);

    function cipherConfig(raw) {
      var config = parse(raw);
      if (!config || typeof config !== 'object' ||
          !own(config, 'algorithm') || !own(config, 'mode') || !own(config, 'padding') || !own(config, 'blockSize') ||
          (config.algorithm !== 'AES' && config.algorithm !== 'DES' && config.algorithm !== 'DESede') ||
          (config.mode !== 'CBC' && config.mode !== 'ECB') ||
          (config.padding !== 'PKCS5Padding' && config.padding !== 'PKCS7Padding' && config.padding !== 'NoPadding') ||
          config.blockSize !== (config.algorithm === 'AES' ? 16 : 8)) {
        throw new fail('NoSuchAlgorithmException: unsupported Cipher configuration');
      }
      return config;
    }
    function cipherKeyAlgorithm(algorithm) {
      algorithm = upper(algorithm);
      return algorithm === 'TRIPLEDES' ? 'DESEDE' : algorithm;
    }
    function cipherOutput(value, offset) {
      var source = byteSource(value);
      if (!source) throw new fail('ShortBufferException: expected a Cipher output byte array');
      copyBytes(source);
      offset = cipherInt(offset, 'Cipher output offset');
      if (offset > source.length) throw new outOfBounds('Cipher output offset out of bounds');
      return { source: source, offset: offset };
    }
    function cipherOutputCapacity(output, length) {
      if (output === null) return;
      var source = output.source;
      if (length > source.length - output.offset) throw new fail('ShortBufferException: Cipher output buffer too small');
      if (source.array) {
        for (var i = 0; i < length; i++) {
          var descriptor = descriptorOf(source.items, output.offset + i);
          if (!descriptor || !own(descriptor, 'value') || !descriptor.writable) {
            throw new fail('IllegalArgumentException: Cipher output array must be writable');
          }
        }
      }
    }
    function cipherStore(output, result) {
      'use strict';
      for (var i = 0; i < result.length; i++) output.source.items[output.offset + i] = result[i];
    }
    function cipherArguments(args, finalizing) {
      var count = args.length, input, output = null;
      if (finalizing && count === 0) input = [];
      else if (count === 1) input = byteArray(args[0]);
      else if (finalizing && count === 2) {
        input = []; output = cipherOutput(args[0], args[1]);
      } else if (count === 3 || count === 4 || count === 5) {
        // Snapshot input before writing output, including overlapping typed-array views.
        input = cipherRange(args[0], args[1], args[2]);
        if (count >= 4) output = cipherOutput(args[3], count === 5 ? args[4] : 0);
      } else throw new fail(finalizing ? 'Unsupported Cipher.doFinal overload' : 'Unsupported Cipher.update overload');
      return { input: input, output: output };
    }
    function cipherJoined(pending, input) {
      var total = pending.length + input.length;
      if (total > 2147483647) throw new outOfBounds('Cipher input length exceeds a Java int');
      var bytes = cipherCopy(pending);
      for (var i = 0; i < input.length; i++) field(bytes, pending.length + i, input[i]);
      return bytes;
    }
    function JCipher() { throw new fail('Cipher must be created with Cipher.getInstance'); }
    JCipher.prototype = create(null);
    JCipher.ENCRYPT_MODE = 1;
    JCipher.DECRYPT_MODE = 2;
    JCipher.getInstance = function(transformation) {
      arity(arguments, 1, 1, 'Cipher.getInstance');
      transformation = text(transformation);
      var config;
      try { config = cipherConfig(javaCipherConfig(transformation)); }
      catch (ignored) { throw new fail('NoSuchAlgorithmException: unsupported Cipher transformation'); }
      var noPadding = config.algorithm + '/' + config.mode + '/NoPadding';
      var keyJson = null, opmode = 0, originalIV = null, nextIV = null, pending = [], busy = false;
      var target = create(JCipher.prototype);
      function initialized() {
        if (keyJson === null) throw new fail('IllegalStateException: Cipher not initialized');
      }
      function begin() {
        if (busy) throw new fail('IllegalStateException: reentrant Cipher operation');
        busy = true;
      }
      function process(bytes, finalizing) {
        try {
          return byteArray(javaCipherProcess(
            finalizing ? transformation : noPadding, opmode, keyJson, cipherBytesJson(nextIV), cipherBytesJson(bytes)
          ));
        } catch (ignored) {
          if (finalizing && opmode === 2 && config.padding !== 'NoPadding') {
            throw new fail('BadPaddingException: Cipher finalization failed');
          }
          throw new fail('GeneralSecurityException: Cipher operation failed');
        }
      }
      method(target, 'getAlgorithm', function() {
        arity(arguments, 0, 0, 'Cipher.getAlgorithm'); return transformation;
      });
      method(target, 'getBlockSize', function() {
        arity(arguments, 0, 0, 'Cipher.getBlockSize'); return config.blockSize;
      });
      method(target, 'getIV', function() {
        arity(arguments, 0, 0, 'Cipher.getIV'); return originalIV === null ? null : cipherCopy(originalIV);
      });
      method(target, 'getOutputSize', function(length) {
        arity(arguments, 1, 1, 'Cipher.getOutputSize'); initialized();
        var total = pending.length + cipherInt(length, 'Cipher input length');
        if (opmode === 1 && config.padding !== 'NoPadding') total = (floor(total / config.blockSize) + 1) * config.blockSize;
        else if (opmode === 2 && config.padding !== 'NoPadding') total = floor((total + config.blockSize - 1) / config.blockSize) * config.blockSize;
        if (total > 2147483647) throw new outOfBounds('Cipher output length exceeds a Java int');
        return total;
      });
      method(target, 'init', function(mode, value, parameters) {
        arity(arguments, 2, 3, 'Cipher.init'); begin();
        try {
          // A rejected reinitialization must not leave the previous key usable.
          keyJson = null; opmode = 0; originalIV = null; nextIV = null; pending = [];
          mode = unbox(mode);
          if (mode !== 1 && mode !== 2) throw new fail('InvalidParameterException: unsupported Cipher opmode');
          var material = value !== null && typeof value === 'object' ? secretKeyGet(value) : null;
          if (!material || cipherKeyAlgorithm(material.algorithm) !== upper(config.algorithm)) {
            throw new fail('InvalidKeyException: Cipher requires a matching SecretKeySpec');
          }
          var iv = null;
          if (arguments.length === 3 && parameters !== null) {
            iv = parameters !== null && typeof parameters === 'object' ? cipherIVGet(parameters) : null;
            if (!iv) throw new fail('InvalidAlgorithmParameterException: Cipher requires an IvParameterSpec');
            iv = cipherCopy(iv);
          }
          if (config.mode === 'ECB' && iv !== null) throw new fail('InvalidAlgorithmParameterException: ECB does not accept an IV');
          if (config.mode === 'CBC' && ((iv === null && mode === 2) || (iv !== null && iv.length !== config.blockSize))) {
            throw new fail('InvalidAlgorithmParameterException: CBC requires a block-sized IV');
          }
          var encodedKey = cipherBytesJson(cipherCopy(material.bytes)), initializedConfig;
          try { initializedConfig = cipherConfig(javaCipherInit(transformation, mode, encodedKey, cipherBytesJson(iv))); }
          catch (ignored) { throw new fail('InvalidKeyException: Cipher initialization failed'); }
          if (initializedConfig.algorithm !== config.algorithm || initializedConfig.mode !== config.mode ||
              initializedConfig.padding !== config.padding || !own(initializedConfig, 'iv')) {
            throw new fail('InvalidAlgorithmParameterException: inconsistent Cipher initialization');
          }
          var actualIV = initializedConfig.iv === null ? null : byteArray(initializedConfig.iv);
          if (config.mode === 'CBC' ? actualIV === null || actualIV.length !== config.blockSize : actualIV !== null) {
            throw new fail('InvalidAlgorithmParameterException: invalid initialized Cipher IV');
          }
          keyJson = encodedKey; opmode = mode; originalIV = actualIV;
          nextIV = actualIV === null ? null : cipherCopy(actualIV);
        } finally { busy = false; }
      });
      method(target, 'update', function() {
        initialized(); begin();
        try {
          var request = cipherArguments(arguments, false), bytes = cipherJoined(pending, request.input);
          if (request.input.length === 0) return request.output !== null ? 0 : null;
          // Android's BC DES buffers a final block on encryption; Conscrypt does not.
          var reserve = config.padding !== 'NoPadding' && (opmode === 2 || config.algorithm === 'DES') ? 1 : 0;
          var available = bytes.length - reserve;
          var consumed = available < 0 ? 0 : floor(available / config.blockSize) * config.blockSize;
          cipherOutputCapacity(request.output, consumed);
          var result = consumed === 0 ? [] : process(cipherCopy(bytes, 0, consumed), false);
          if (result.length !== consumed) throw new fail('GeneralSecurityException: invalid Cipher update output size');
          var followingIV = nextIV;
          if (consumed && config.mode === 'CBC') {
            followingIV = opmode === 1 ? cipherCopy(result, consumed - config.blockSize) : cipherCopy(bytes, consumed - config.blockSize, consumed);
          }
          var remaining = cipherCopy(bytes, consumed);
          if (request.output !== null) cipherStore(request.output, result);
          pending = remaining; nextIV = followingIV;
          return request.output !== null ? result.length : result.length || config.algorithm !== 'DES' ? result : null;
        } finally { busy = false; }
      });
      method(target, 'doFinal', function() {
        initialized(); begin();
        try {
          var request = cipherArguments(arguments, true), bytes = cipherJoined(pending, request.input);
          if ((opmode === 2 || config.padding === 'NoPadding') && bytes.length % config.blockSize !== 0) {
            throw new fail('IllegalBlockSizeException: Cipher input is not block aligned');
          }
          if (opmode === 2 && config.algorithm === 'DES' && config.padding !== 'NoPadding' && bytes.length === 0) {
            throw new fail('IllegalBlockSizeException: DES padded decryption requires a complete block');
          }
          var result = process(bytes, true);
          // The host is stateless: short output buffers can retry without consuming input or CBC state.
          cipherOutputCapacity(request.output, result.length);
          if (request.output !== null) cipherStore(request.output, result);
          pending = []; nextIV = originalIV === null ? null : cipherCopy(originalIV);
          return request.output !== null ? result.length : result;
        } finally { busy = false; }
      });
      return target;
    };
""".trimIndent()
