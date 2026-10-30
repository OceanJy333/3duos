// input: nothing at run time; MSL source spliced into PICAMetalShaders.draw.
// output: `lightFragment`, the GPU port of PICALightingPipeline.evaluate (same LUT format and inputs).
// pos: fragment lighting for the Metal backend; the uniform block layout is PICAMetalShaders' `Draw`/`Light`.

extension PICAMetalShaders {
    static let lighting = """
    static float lightSample(const device uint *lut, int table, int index, float delta) {
        uint e = lut[table * 256 + index];
        float difference = float((e >> 12) & 0x7FF) / 2047;
        return float(e & 0xFFF) / 4095 + (((e >> 23) & 1) != 0 ? -difference : difference) * delta;
    }

    static float lightLookup(constant Draw &d, const device uint *lut, int input, float value, int table, bool twoSided) {
        int4 i = d.inputs[input];
        float scale = d.scales[input / 4][input % 4], v = value, delta; int index;
        if (i.z != 0) {
            v = twoSided ? abs(v) : max(v, 0.0);
            float f = clamp(floor(v * 256), 0.0, 255.0);
            index = int(f); delta = v * 256 - f;
        } else {
            float f = clamp(floor(v * 128), -128.0, 127.0);
            index = int(f) & 255; delta = v * 128 - f;
        }
        return scale * lightSample(lut, table, index, delta);
    }

    static float3 rotate(float4 q, float3 v) { return v + 2 * cross(q.xyz, cross(q.xyz, v) + v * q.w); }

    static void lightFragment(constant Draw &d, const device uint *lut, float4 quaternion, float3 view, thread int4 &primary, thread int4 &secondary) {
        float4 q = quaternion / sqrt(dot(quaternion, quaternion));
        float3 normal = rotate(q, float3(0, 0, 1)), normView = normalize(view);
        float4 diffuse = float4(0, 0, 0, 1), specular = float4(0, 0, 0, 1);
        int count = d.lighting.x;
        for (int n = 0; n < count; n++) {
            Light light = d.lights[n];
            bool twoSided = light.flags.y != 0;
            float3 lightVector = light.flags.x != 0 ? light.position.xyz : light.position.xyz + view;
            float length = sqrt(dot(lightVector, lightVector));
            lightVector /= length;
            float3 halfVector = normView + lightVector, halfNormalized = normalize(halfVector);
            float angles[6] = { dot(normal, halfNormalized), dot(normView, halfNormalized), dot(normal, normView),
                                dot(lightVector, normal), dot(lightVector, light.spot.xyz), 0 };
            #define VALUE(input, table) lightLookup(d, lut, input, angles[min(d.inputs[input].y, 5)], table, twoSided)
            float distance = 1;
            if (light.more.z != 0) {
                float at = clamp(light.distance.y * length + light.distance.x, 0.0, 1.0);
                float index = clamp(floor(at * 256), 0.0, 255.0);
                distance = lightSample(lut, 16 + light.more.x, int(index), at * 256 - index);
            }
            float spot = light.more.y != 0 ? VALUE(6, 8 + light.more.x) : 1;
            float3 specular0 = (d.inputs[0].x != 0 ? VALUE(0, d.inputs[0].w) : 1) * light.specular0.xyz;
            float3 reflect = float3(d.inputs[3].x != 0 ? VALUE(3, d.inputs[3].w) : 1);
            if (d.inputs[4].x != 0) reflect.y = VALUE(4, d.inputs[4].w);
            if (d.inputs[5].x != 0) reflect.z = VALUE(5, d.inputs[5].w);
            float3 specular1 = (d.inputs[1].x != 0 ? VALUE(1, d.inputs[1].w) : 1) * reflect * light.specular1.xyz;
            if (n == count - 1 && d.inputs[2].x != 0) {
                float f = VALUE(2, d.inputs[2].w);
                if (d.lighting.z != 0) diffuse.w = f;
                if (d.lighting.w != 0) specular.w = f;
            }
            #undef VALUE
            float dd = dot(lightVector, normal);
            dd = twoSided ? abs(dd) : max(dd, 0.0);
            float clampFactor = d.lighting.y != 0 && dd == 0 ? 0 : 1;
            if (light.flags.z != 0 || light.flags.w != 0) {
                float g = dot(halfVector, halfVector), factor = g == 0 ? 0 : min(dd / g, 1.0);
                if (light.flags.z != 0) specular0 *= factor;
                if (light.flags.w != 0) specular1 *= factor;
            }
            diffuse.xyz += (light.diffuse.xyz * dd + light.ambient.xyz) * distance * spot;
            specular.xyz += (specular0 + specular1) * clampFactor * distance * spot;
        }
        diffuse.xyz += d.ambient.xyz;
        primary = int4(select(float4(0), min(diffuse, 1.0) * 255, diffuse > 0));
        secondary = int4(select(float4(0), min(specular, 1.0) * 255, specular > 0));
    }
    """
}
