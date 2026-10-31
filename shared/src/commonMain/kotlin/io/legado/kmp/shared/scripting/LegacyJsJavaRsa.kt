package io.legado.kmp.shared.scripting

// Installed in the Java shim closure alongside the byte-array and Cipher helpers.
internal val LEGACY_JS_JAVA_RSA = """
    var javaRsaKey = __legacyJavaRsaKey;
    var javaRsaCipher = __legacyJavaRsaCipher;
    var javaRsaSign = __legacyJavaRsaSign;
    var javaRsaVerify = __legacyJavaRsaVerify;
    var rsaKeySpecs = new WeakMap();
    var rsaKeySpecGet = Function.prototype.call.bind(WeakMap.prototype.get, rsaKeySpecs);
    var rsaKeySpecSet = Function.prototype.call.bind(WeakMap.prototype.set, rsaKeySpecs);
    var rsaKeys = new WeakMap();
    var rsaKeyGet = Function.prototype.call.bind(WeakMap.prototype.get, rsaKeys);
    var rsaKeySet = Function.prototype.call.bind(WeakMap.prototype.set, rsaKeys);

    function rsaMaterial(value) {
      return value !== null && typeof value === 'object' ? rsaKeyGet(value) : null;
    }
    function rsaEncodedKeySpec(ctor, kind, value) {
      var bytes = byteArray(value), format = kind === 'public' ? 'X.509' : 'PKCS#8';
      var target = create(ctor.prototype);
      rsaKeySpecSet(target, { kind: kind, bytes: bytes });
      method(target, 'getEncoded', function() {
        arity(arguments, 0, 0, 'EncodedKeySpec.getEncoded'); return cipherCopy(bytes);
      });
      method(target, 'getFormat', function() {
        arity(arguments, 0, 0, 'EncodedKeySpec.getFormat'); return format;
      });
      method(target, 'getAlgorithm', function() {
        arity(arguments, 0, 0, 'EncodedKeySpec.getAlgorithm'); return null;
      });
      return target;
    }
    function JX509EncodedKeySpec(value) {
      arity(arguments, 1, 1, 'X509EncodedKeySpec');
      return rsaEncodedKeySpec(JX509EncodedKeySpec, 'public', value);
    }
    JX509EncodedKeySpec.prototype = create(null);
    function JPKCS8EncodedKeySpec(value) {
      arity(arguments, 1, 1, 'PKCS8EncodedKeySpec');
      return rsaEncodedKeySpec(JPKCS8EncodedKeySpec, 'private', value);
    }
    JPKCS8EncodedKeySpec.prototype = create(null);

    function JKey() { throw new fail('Key is an interface'); }
    function JPublicKey() { throw new fail('PublicKey is an interface'); }
    function JPrivateKey() { throw new fail('PrivateKey is an interface'); }
    function JRsaPublicKey() { throw new fail('RSAPublicKey is an interface'); }
    function JRsaPrivateKey() { throw new fail('RSAPrivateKey is an interface'); }
    function rsaKeyInterface(ctor, parent, kind) {
      ctor.prototype = create(parent === null ? null : parent.prototype);
      // Prototype chains and copied methods are not proof of key provenance, even for instanceof.
      define(ctor, Symbol.hasInstance, { value: function(value) {
        var material = rsaMaterial(value);
        return !!material && (kind === null || material.kind === kind);
      } });
    }
    rsaKeyInterface(JKey, null, null);
    rsaKeyInterface(JPublicKey, JKey, 'public');
    rsaKeyInterface(JPrivateKey, JKey, 'private');
    rsaKeyInterface(JRsaPublicKey, JPublicKey, 'public');
    rsaKeyInterface(JRsaPrivateKey, JPrivateKey, 'private');

    function rsaKeyMetadata(raw, kind) {
      var material = parse(raw), format = kind === 'public' ? 'X.509' : 'PKCS#8';
      if (!material || typeof material !== 'object' ||
          !own(material, 'kind') || !own(material, 'algorithm') || !own(material, 'format') ||
          !own(material, 'encoded') || !own(material, 'blockSize') ||
          material.kind !== kind || material.algorithm !== 'RSA' || material.format !== format ||
          !isArray(material.encoded) || material.encoded.length === 0 ||
          typeof material.blockSize !== 'number' || !integer(material.blockSize) ||
          material.blockSize <= 11 || material.blockSize > 2147483647) {
        throw new fail('InvalidKeySpecException: invalid RSA key metadata');
      }
      for (var i = 0; i < material.encoded.length; i++) {
        var byte = material.encoded[i];
        if (typeof byte !== 'number' || !integer(byte) || byte < 0 || byte > 255) {
          throw new fail('InvalidKeySpecException: invalid RSA key encoding');
        }
      }
      var bytes = byteArray(material.encoded);
      // All RSA keyJson arguments carry DER byte-array JSON, not the metadata or facade object.
      return { kind: kind, format: format, bytes: bytes, keyJson: cipherBytesJson(bytes), blockSize: material.blockSize };
    }
    function rsaGenerateKey(value, kind) {
      var spec = value !== null && typeof value === 'object' ? rsaKeySpecGet(value) : null;
      if (!spec || spec.kind !== kind) {
        throw new fail('InvalidKeySpecException: RSA requires a matching encoded KeySpec');
      }
      var material;
      try { material = rsaKeyMetadata(javaRsaKey(kind, cipherBytesJson(spec.bytes)), kind); }
      catch (ignored) { throw new fail('InvalidKeySpecException: invalid RSA key encoding'); }
      var target = create(kind === 'public' ? JRsaPublicKey.prototype : JRsaPrivateKey.prototype);
      rsaKeySet(target, material);
      method(target, 'getAlgorithm', function() {
        arity(arguments, 0, 0, 'Key.getAlgorithm'); return 'RSA';
      });
      method(target, 'getFormat', function() {
        arity(arguments, 0, 0, 'Key.getFormat'); return material.format;
      });
      method(target, 'getEncoded', function() {
        arity(arguments, 0, 0, 'Key.getEncoded'); return cipherCopy(material.bytes);
      });
      return target;
    }
    function JKeyFactory() { throw new fail('KeyFactory must be created with KeyFactory.getInstance'); }
    JKeyFactory.prototype = create(null);
    JKeyFactory.getInstance = function(algorithm) {
      arity(arguments, 1, 1, 'KeyFactory.getInstance'); algorithm = text(algorithm);
      if (upper(algorithm) !== 'RSA') throw new fail('NoSuchAlgorithmException: unsupported KeyFactory algorithm');
      var target = create(JKeyFactory.prototype);
      method(target, 'getAlgorithm', function() {
        arity(arguments, 0, 0, 'KeyFactory.getAlgorithm'); return algorithm;
      });
      method(target, 'generatePublic', function(value) {
        arity(arguments, 1, 1, 'KeyFactory.generatePublic'); return rsaGenerateKey(value, 'public');
      });
      method(target, 'generatePrivate', function(value) {
        arity(arguments, 1, 1, 'KeyFactory.generatePrivate'); return rsaGenerateKey(value, 'private');
      });
      method(target, 'getKeySpec', function() {
        throw new fail('Unsupported KeyFactory.getKeySpec');
      });
      method(target, 'translateKey', function() {
        throw new fail('Unsupported KeyFactory.translateKey');
      });
      return target;
    };

    function rsaSignatureAlgorithm(value) {
      var name = upper(value);
      if (name === 'SHA1WITHRSA') return { name: 'SHA1withRSA', encodedLength: 35 };
      if (name === 'SHA224WITHRSA') return { name: 'SHA224withRSA', encodedLength: 47 };
      if (name === 'SHA256WITHRSA') return { name: 'SHA256withRSA', encodedLength: 51 };
      if (name === 'SHA384WITHRSA') return { name: 'SHA384withRSA', encodedLength: 67 };
      if (name === 'SHA512WITHRSA') return { name: 'SHA512withRSA', encodedLength: 83 };
      throw new fail('NoSuchAlgorithmException: unsupported RSA Signature algorithm');
    }
    function rsaSignatureInt(value, name) {
      value = unbox(value);
      if (typeof value !== 'number' || !integer(value) || value < 0 || value > 2147483647) {
        throw new fail('IllegalArgumentException: ' + name + ' must be a non-negative Java int');
      }
      return value;
    }
    function rsaSignatureRange(value, offset, length) {
      if (value == null) throw new fail('IllegalArgumentException: missing Signature byte array');
      var bytes = byteArray(value);
      offset = rsaSignatureInt(offset, 'Signature offset');
      length = rsaSignatureInt(length, 'Signature length');
      if (offset > bytes.length || length > bytes.length - offset) {
        throw new fail('IllegalArgumentException: Signature input range out of bounds');
      }
      return cipherCopy(bytes, offset, offset + length);
    }
    function rsaSignatureOutput(value, offset, length) {
      var source = byteSource(value);
      if (!source) throw new fail('IllegalArgumentException: expected a Signature output byte array');
      copyBytes(source);
      offset = rsaSignatureInt(offset, 'Signature output offset');
      length = rsaSignatureInt(length, 'Signature output length');
      if (offset > source.length || length > source.length - offset) {
        throw new fail('IllegalArgumentException: Signature output range out of bounds');
      }
      return { source: source, offset: offset, length: length };
    }
    function JSignature() { throw new fail('Signature must be created with Signature.getInstance'); }
    JSignature.prototype = create(null);
    JSignature.getInstance = function(algorithm) {
      arity(arguments, 1, 1, 'Signature.getInstance'); algorithm = text(algorithm);
      var spec = rsaSignatureAlgorithm(algorithm), key = null, mode = 0, pending = [], busy = false;
      var target = create(JSignature.prototype);
      function begin() {
        if (busy) throw new fail('IllegalStateException: reentrant Signature operation');
        busy = true;
      }
      function initialized(required) {
        if (key === null || (required !== 0 && mode !== required)) {
          throw new fail('SignatureException: Signature not initialized for this operation');
        }
      }
      function initialize(value, kind, nextMode, args, name) {
        begin();
        try {
          // Even an unsupported init overload invalidates the previous key and message.
          key = null; mode = 0; pending = [];
          arity(args, 1, 1, name);
          var material = rsaMaterial(value);
          if (!material || material.kind !== kind) {
            throw new fail('InvalidKeyException: Signature requires an RSA ' + kind + ' key');
          }
          if (material.blockSize < spec.encodedLength + 11) {
            throw new fail('InvalidKeyException: RSA key too short for Signature algorithm');
          }
          key = material; mode = nextMode;
        } finally { busy = false; }
      }
      method(target, 'getAlgorithm', function() {
        arity(arguments, 0, 0, 'Signature.getAlgorithm'); return algorithm;
      });
      method(target, 'initSign', function(value) {
        initialize(value, 'private', 1, arguments, 'Signature.initSign');
      });
      method(target, 'initVerify', function(value) {
        initialize(value, 'public', 2, arguments, 'Signature.initVerify');
      });
      method(target, 'update', function(value, offset, length) {
        begin();
        try {
          initialized(0);
          if (arguments.length !== 1 && arguments.length !== 3) throw new fail('Unsupported Signature.update overload');
          var bytes, raw = unbox(value);
          if (arguments.length === 1 && typeof raw === 'number') bytes = byteArray([raw]);
          else bytes = arguments.length === 1 ? byteArray(value) : rsaSignatureRange(value, offset, length);
          pending = cipherJoined(pending, bytes);
        } finally { busy = false; }
      });
      method(target, 'sign', function(value, offset, length) {
        begin();
        try {
          initialized(1);
          if (arguments.length !== 0 && arguments.length !== 3) throw new fail('Unsupported Signature.sign overload');
          var output = arguments.length === 0 ? null : rsaSignatureOutput(value, offset, length);
          var result;
          try { result = byteArray(javaRsaSign(spec.name, key.keyJson, cipherBytesJson(pending))); }
          catch (ignored) { throw new fail('SignatureException: RSA signing failed'); }
          // Signing resets the message before checking output capacity, unlike Cipher.doFinal.
          pending = [];
          if (result.length !== key.blockSize) throw new fail('SignatureException: invalid RSA signature size');
          if (output !== null) {
            if (output.length < result.length) throw new fail('SignatureException: Signature output buffer too small');
            cipherOutputCapacity(output, result.length);
            cipherStore(output, result);
          }
          return output !== null ? result.length : result;
        } finally { busy = false; }
      });
      method(target, 'verify', function(value, offset, length) {
        begin();
        try {
          initialized(2);
          if (arguments.length !== 1 && arguments.length !== 3) throw new fail('Unsupported Signature.verify overload');
          var signature = arguments.length === 1 ? byteArray(value) : rsaSignatureRange(value, offset, length);
          var result;
          try { result = javaRsaVerify(spec.name, key.kind, key.keyJson, cipherBytesJson(pending), cipherBytesJson(signature)); }
          catch (ignored) { throw new fail('SignatureException: RSA verification failed'); }
          if (typeof result !== 'boolean') throw new fail('SignatureException: invalid RSA verification result');
          pending = [];
          return result;
        } finally { busy = false; }
      });
      return target;
    };

    function rsaCipherTransformation(value) {
      var parts = split(value, '/');
      if (parts.length === 1) return upper(trim(parts[0])) === 'RSA';
      return parts.length === 3 && upper(trim(parts[0])) === 'RSA' &&
        (upper(trim(parts[1])) === 'ECB' || upper(trim(parts[1])) === 'NONE') &&
        upper(trim(parts[2])) === 'PKCS1PADDING';
    }
    function rsaCipher(transformation) {
      var key = null, opmode = 0, pending = [], busy = false;
      var target = create(JCipher.prototype);
      function begin() {
        if (busy) throw new fail('IllegalStateException: reentrant Cipher operation');
        busy = true;
      }
      function initialized() {
        if (key === null) throw new fail('IllegalStateException: Cipher not initialized');
      }
      method(target, 'getAlgorithm', function() {
        arity(arguments, 0, 0, 'Cipher.getAlgorithm'); return transformation;
      });
      method(target, 'getBlockSize', function() {
        arity(arguments, 0, 0, 'Cipher.getBlockSize'); return 0;
      });
      method(target, 'getIV', function() {
        arity(arguments, 0, 0, 'Cipher.getIV'); return null;
      });
      method(target, 'getOutputSize', function(length) {
        arity(arguments, 1, 1, 'Cipher.getOutputSize'); initialized();
        cipherInt(length, 'Cipher input length'); return key.blockSize;
      });
      method(target, 'init', function(mode, value, parameters) {
        begin();
        try {
          key = null; opmode = 0; pending = [];
          arity(arguments, 2, 3, 'Cipher.init');
          mode = unbox(mode);
          if (mode !== 1 && mode !== 2) throw new fail('InvalidParameterException: unsupported Cipher opmode');
          var material = rsaMaterial(value);
          if (!material) throw new fail('InvalidKeyException: Cipher requires an RSA key');
          if (arguments.length === 3 && parameters !== null) {
            throw new fail('InvalidAlgorithmParameterException: RSA Cipher does not accept parameters');
          }
          key = material; opmode = mode;
        } finally { busy = false; }
      });
      method(target, 'update', function() {
        begin();
        try {
          initialized();
          var request = cipherArguments(arguments, false), bytes = cipherJoined(pending, request.input);
          cipherOutputCapacity(request.output, 0);
          pending = bytes;
          return request.output !== null ? 0 : request.input.length === 0 ? null : [];
        } finally { busy = false; }
      });
      method(target, 'doFinal', function() {
        begin();
        try {
          initialized();
          var request = cipherArguments(arguments, true), bytes = cipherJoined(pending, request.input);
          var maximum = opmode === 1 ? key.blockSize - 11 : key.blockSize;
          if (bytes.length > maximum) throw new fail('IllegalBlockSizeException: RSA input exceeds one PKCS1 block');
          // RSA emits at most one modulus-sized block; a short buffer must preserve pending input.
          cipherOutputCapacity(request.output, key.blockSize);
          var result;
          try { result = byteArray(javaRsaCipher(opmode, key.kind, key.keyJson, cipherBytesJson(bytes))); }
          catch (ignored) {
            if (opmode === 2) throw new fail('BadPaddingException: RSA Cipher finalization failed');
            throw new fail('GeneralSecurityException: RSA Cipher operation failed');
          }
          if (opmode === 1 ? result.length !== key.blockSize : result.length > key.blockSize - 11) {
            throw new fail('GeneralSecurityException: invalid RSA Cipher output size');
          }
          cipherOutputCapacity(request.output, result.length);
          if (request.output !== null) cipherStore(request.output, result);
          pending = [];
          return request.output !== null ? result.length : result;
        } finally { busy = false; }
      });
      return target;
    }
""".trimIndent()
