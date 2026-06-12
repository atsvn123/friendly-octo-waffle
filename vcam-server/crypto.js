// crypto.js
// XOR cipher matching the implementation in vcamera.dylib (kEncKey, xorTransform).
// Key: "VCAM9#iOS3d#wKEK" (16 bytes, repeating).
// Both request body and response JSON use the same transform.

const XOR_KEY = Buffer.from('VCAM9#iOS3d#wKEK', 'ascii'); // 16 bytes

function xorTransform(buf) {
    const out = Buffer.alloc(buf.length);
    for (let i = 0; i < buf.length; i++) {
        out[i] = buf[i] ^ XOR_KEY[i % XOR_KEY.length];
    }
    return out;
}

// Encrypt a plain JSON object → Buffer ready to send as response body.
function encryptResponse(obj) {
    return xorTransform(Buffer.from(JSON.stringify(obj), 'utf8'));
}

// Decrypt a raw request body Buffer → UTF-8 string.
function decryptBody(buf) {
    return xorTransform(buf).toString('utf8');
}

module.exports = { xorTransform, encryptResponse, decryptBody };
