#include "../../postFx/postFx.hlsl"
#include "../../shaderModel.hlsl"
#include "../../shaderModelAutoGen.hlsl"
#include "../../lighting.hlsl"

TORQUE_UNIFORM_SAMPLER2D(deferredBuffer, 0);
TORQUE_UNIFORM_SAMPLER2D(colorBuffer, 1);
TORQUE_UNIFORM_SAMPLER2D(matInfoBuffer, 2);
TORQUE_UNIFORM_SAMPLER2D(BRDFTexture, 3);

uniform float4 rtParams0;
uniform float4 vsFarPlane;
uniform float4x4 cameraToWorld;
uniform float3 eyePosWorld;

//cubemap arrays require all the same size. so shared mips# value
uniform float cubeMips;
#define MAX_PROBES 50

uniform float numProbes;
TORQUE_UNIFORM_SAMPLERCUBEARRAY(cubeMapAR, 4);
TORQUE_UNIFORM_SAMPLERCUBEARRAY(irradianceCubemapAR, 5);

uniform float4    inProbePosArray[MAX_PROBES];
uniform float4    inRefPosArray[MAX_PROBES];
uniform float4x4  worldToObjArray[MAX_PROBES];
uniform float4    bbMinArray[MAX_PROBES];
uniform float4    bbMaxArray[MAX_PROBES];
uniform float4    probeConfigData[MAX_PROBES];   //r,g,b/mode,radius,atten

#if DEBUGVIZ_CONTRIB
uniform float4    probeContribColors[MAX_PROBES]; 
#endif

// Box Projected IBL Lighting
// Based on: http://www.gamedev.net/topic/568829-box-projected-cubemap-environment-mapping/
// and https://seblagarde.wordpress.com/2012/09/29/image-based-lighting-approaches-and-parallax-corrected-cubemap/
/*float3 boxProject(float3 wsPosition, float3 wsEyeRay, float3 reflectDir, float3 boxWSPos, float3 boxMin, float3 boxMax)
{ 
   float3 positionLS = mul(worldToObjArray[id], float4(wsEyeRay, 1.0)).xyz;
   //float3 rayLS = mul(worldToObjArray[id], float4(wsEyeRay, 1.0)).xyz;
   //float3 reflCameraLS = mul(worldToObjArray[id], float4(reflectDir), 1.0)).xyz;

   float3 nrdir = reflectDir;
	float3 offset = wsPosition;
   float3 plane1vec = (boxMax - offset) / nrdir;
   float3 plane2vec = (boxMin - offset) / nrdir;
	
	float3 furthestPlane = max(plane1vec, plane2vec);
	float dist = min(min(furthestPlane.x, furthestPlane.y), furthestPlane.z);
   float3 posonbox = offset + nrdir * dist;

   return posonbox - boxWSPos;
}*/


float3 iblBoxDiffuse( Surface surface, ProbeData probe)
{
   float3 dir = boxProject(surface, probe);

   float lod = surface.roughness*cubeMips;
   float3 color = TORQUE_TEXCUBEARRAYLOD(irradianceCubemapAR, dir, probe.probeIdx, lod).xyz;

   return color;
}

float3 iblBoxSpecular(Surface surface, ProbeData probe)
{
    // BRDF
   float2 brdf = TORQUE_TEX2DLOD(BRDFTexture, float4(surface.roughness, surface.NdotV,0.0,0.0)).xy;

   float3 dir = boxProject(surface, probe);

    // Radiance (Specular)
#if DEBUGVIZ_SPECCUBEMAP == 0
   float lod = surface.roughness*cubeMips;
#elif DEBUGVIZ_SPECCUBEMAP == 1
   float lod = 0;
#endif

   float3 color = TORQUE_TEXCUBEARRAYLOD(cubeMapAR, dir, probe.probeIdx, lod).xyz * (brdf.x + brdf.y);

   return color;
}

float4 main( PFXVertToPix IN ) : SV_TARGET
{
   //unpack normal and linear depth 
   float4 normDepth = TORQUE_DEFERRED_UNCONDITION(deferredBuffer, IN.uv0.xy);

   //create surface
   Surface surface = createSurface( normDepth, TORQUE_SAMPLER2D_MAKEARG(colorBuffer),TORQUE_SAMPLER2D_MAKEARG(matInfoBuffer),
                                    IN.uv0.xy, eyePosWorld, IN.wsEyeRay, cameraToWorld);

   //early out if emissive
   if (getFlag(surface.matFlag, 0))
   {   
      discard;
   }     

   int i = 0;
   float blendVal[MAX_PROBES];
   float blendFactor[MAX_PROBES];
   float blendSum = 0;
   float blendFacSum = 0;
   float invBlendSum = 0;

   //Set up our struct data
   ProbeData probes[MAX_PROBES];

   //Process prooooobes
   for (i = 0; i < numProbes; ++i)
   {
      probes[i].wsPosition = inProbePosArray[i].xyz;
      probes[i].radius = probeConfigData[i].g;
      probes[i].boxMin = bbMinArray[i].xyz;
      probes[i].boxMax = bbMaxArray[i].xyz;
      probes[i].refPosition = inRefPosArray[i].xyz;
      probes[i].attenuation = probeConfigData[i].b;
      probes[i].worldToLocal = worldToObjArray[i];
      probes[i].probeIdx = i;
      probes[i].type = probeConfigData[i].r;
      probes[i].contribution = 0;

      if (probes[i].type == 0) //box
      {
         blendVal[i] = defineBoxSpaceInfluence(surface, probes[i], IN.wsEyeRay);
      }
      else
      {
         blendVal[i] = defineSphereSpaceInfluence(surface, probes[i], IN.wsEyeRay);
      }

      blendVal[i] = saturate(blendVal[i]);
      blendSum += blendVal[i];
      invBlendSum += (1.0f - blendVal[i]);
   }

   // Weight0 = normalized NDF, inverted to have 1 at center, 0 at boundary.
   // And as we invert, we need to divide by Num-1 to stay normalized (else sum is > 1). 
   // respect constraint B.
   // Weight1 = normalized inverted NDF, so we have 1 at center, 0 at boundary
   // and respect constraint A.
   for (i = 0; i < numProbes; i++)
   {
      if (numProbes>1)
      {
         blendFactor[i] = ((1.0f - blendVal[i] / blendSum)) / (numProbes - 1);
         blendFactor[i] *= ((1.0f - blendVal[i]) / invBlendSum);
         blendFacSum += blendFactor[i];
      }
      else
      {
         blendFactor[i] = blendVal[i];
         blendFacSum = blendVal[i];
      }
   }

   // Normalize blendVal
#if DEBUGVIZ_ATTENUATION == 0 //this can likely be removed when we fix the above normalization behavior
   if (blendFacSum == 0.0f) // Possible with custom weight
   {
      blendFacSum = 1.0f;
   }
#endif

   float invBlendSumWeighted = 1.0f / blendFacSum;
   for (i = 0; i < numProbes; ++i)
   {
      blendFactor[i] *= invBlendSumWeighted;
   }
   
#if DEBUGVIZ_ATTENUATION == 1
   return float4(blendFacSum, blendFacSum, blendFacSum, 1);
#endif

#if DEBUGVIZ_CONTRIB == 1

   float3 finalContribColor = float3(0, 0, 0);
   for (i = 0; i < numProbes; ++i)
   {
      if (blendFactor[i] == 0)
         continue;

      finalContribColor += blendFactor[i] * probeContribColors[i].rgb;
   }

   return float4(finalContribColor, 1);
#endif

#if DEBUGVIZ_SPECCUBEMAP == 0 && DEBUGVIZ_DIFFCUBEMAP == 0

   float3 irradiance = float3(0, 0, 0);
   float3 specular = float3(0, 0, 0);
   float3 F = FresnelSchlickRoughness(surface.NdotV, surface.f0, surface.roughness);

   //energy conservation
   float3 kD = 1.0.xxx - F;
   kD *= 1.0 - surface.metalness;
   for (i = 0; i < numProbes; ++i)
   {
      if (blendVal[i] == 0)
         continue;

      irradiance += blendFactor[i]*iblBoxDiffuse(surface, probes[i]);
      
      specular += blendFactor[i]*F*iblBoxSpecular(surface, probes[i]);
   }

   //final diffuse color
   float3 diffuse = kD * irradiance * surface.baseColor.rgb;
   float4 finalColor = float4(diffuse + specular * surface.ao, blendFacSum);

   return finalColor;

#elif DEBUGVIZ_SPECCUBEMAP == 1 && DEBUGVIZ_DIFFCUBEMAP == 0
   float3 cubeColor = float3(0, 0, 0);
   for (i = 0; i < numProbes; ++i)
   {
      cubeColor += blendFactor[i] * iblBoxSpecular(surface, probes[i]);
   }

   return float4(cubeColor, 1);
#elif DEBUGVIZ_DIFFCUBEMAP == 1
   float3 cubeColor = float3(0, 0, 0);
   for (i = 0; i < numProbes; ++i)
   {
      cubeColor += blendFactor[i] * iblBoxDiffuse(surface, probes[i]);
   }

   return float4(cubeColor, 1);
#endif
}
