import{M as m,O as Mt,B as we,F as rt,S as ge,U as Ge,V,W as ye,H as Ae,N as Dt,T as zt,R as Lt,C as Gt,a as Ut,L as Ht,b as kt,c as Qt,A as Wt,d as Vt,e as $t,f as Kt,g as H,h as $,i as Ue,j as Xe,k as x,l as te,m as jt,n as xt,o as St,p as Tt,q as Ce,I as Yt,r as qt,P as $e,s as Xt,t as ne,D as Zt,u as nt,G as Y,v as Jt,w as _t,x as lt,y as ct,z as es,E as ts,J as ss,K as ft,Q as os,X as ut,Y as is,Z as as}from"./three.module-BdBjs4bv.js";import{I as Ct,T as le,E as rs,i as _e,S as ns,P as ls,B as Ke,M as cs,m as Oe,a as fs,b as ht,c as us,d as hs,e as ds,F as ps,f as dt}from"./Landing-CofhY7_t.js";import"./index-CXUpWPgo.js";const Le={name:"CopyShader",uniforms:{tDiffuse:{value:null},opacity:{value:1}},vertexShader:`

		varying vec2 vUv;

		void main() {

			vUv = uv;
			gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

		}`,fragmentShader:`

		uniform float opacity;

		uniform sampler2D tDiffuse;

		varying vec2 vUv;

		void main() {

			vec4 texel = texture2D( tDiffuse, vUv );
			gl_FragColor = opacity * texel;


		}`};class ve{constructor(){this.isPass=!0,this.enabled=!0,this.needsSwap=!0,this.clear=!1,this.renderToScreen=!1}setSize(){}render(){console.error("THREE.Pass: .render() must be implemented in derived pass.")}dispose(){}}const ms=new Mt(-1,1,1,-1,0,1);class gs extends we{constructor(){super(),this.setAttribute("position",new rt([-1,3,0,-1,-1,0,3,-1,0],3)),this.setAttribute("uv",new rt([0,2,0,0,2,0],2))}}const ws=new gs;class Je{constructor(e){this._mesh=new m(ws,e)}dispose(){this._mesh.geometry.dispose()}render(e){e.render(this._mesh,ms)}get material(){return this._mesh.material}set material(e){this._mesh.material=e}}class bs extends ve{constructor(e,t="tDiffuse"){super(),this.textureID=t,this.uniforms=null,this.material=null,e instanceof ge?(this.uniforms=e.uniforms,this.material=e):e&&(this.uniforms=Ge.clone(e.uniforms),this.material=new ge({name:e.name!==void 0?e.name:"unspecified",defines:Object.assign({},e.defines),uniforms:this.uniforms,vertexShader:e.vertexShader,fragmentShader:e.fragmentShader})),this._fsQuad=new Je(this.material)}render(e,t,s){this.uniforms[this.textureID]&&(this.uniforms[this.textureID].value=s.texture),this._fsQuad.material=this.material,this.renderToScreen?(e.setRenderTarget(null),this._fsQuad.render(e)):(e.setRenderTarget(t),this.clear&&e.clear(e.autoClearColor,e.autoClearDepth,e.autoClearStencil),this._fsQuad.render(e))}dispose(){this.material.dispose(),this._fsQuad.dispose()}}class pt extends ve{constructor(e,t){super(),this.scene=e,this.camera=t,this.clear=!0,this.needsSwap=!1,this.inverse=!1}render(e,t,s){const o=e.getContext(),i=e.state;i.buffers.color.setMask(!1),i.buffers.depth.setMask(!1),i.buffers.color.setLocked(!0),i.buffers.depth.setLocked(!0);let r,u;this.inverse?(r=0,u=1):(r=1,u=0),i.buffers.stencil.setTest(!0),i.buffers.stencil.setOp(o.REPLACE,o.REPLACE,o.REPLACE),i.buffers.stencil.setFunc(o.ALWAYS,r,4294967295),i.buffers.stencil.setClear(u),i.buffers.stencil.setLocked(!0),e.setRenderTarget(s),this.clear&&e.clear(),e.render(this.scene,this.camera),e.setRenderTarget(t),this.clear&&e.clear(),e.render(this.scene,this.camera),i.buffers.color.setLocked(!1),i.buffers.depth.setLocked(!1),i.buffers.color.setMask(!0),i.buffers.depth.setMask(!0),i.buffers.stencil.setLocked(!1),i.buffers.stencil.setFunc(o.EQUAL,1,4294967295),i.buffers.stencil.setOp(o.KEEP,o.KEEP,o.KEEP),i.buffers.stencil.setLocked(!0)}}class vs extends ve{constructor(){super(),this.needsSwap=!1}render(e){e.state.buffers.stencil.setLocked(!1),e.state.buffers.stencil.setTest(!1)}}class Ms{constructor(e,t){if(this.renderer=e,this._pixelRatio=e.getPixelRatio(),t===void 0){const s=e.getSize(new V);this._width=s.width,this._height=s.height,t=new ye(this._width*this._pixelRatio,this._height*this._pixelRatio,{type:Ae}),t.texture.name="EffectComposer.rt1"}else this._width=t.width,this._height=t.height;this.renderTarget1=t,this.renderTarget2=t.clone(),this.renderTarget2.texture.name="EffectComposer.rt2",this.writeBuffer=this.renderTarget1,this.readBuffer=this.renderTarget2,this.renderToScreen=!0,this.passes=[],this.copyPass=new bs(Le),this.copyPass.material.blending=Dt,this.timer=new zt}swapBuffers(){const e=this.readBuffer;this.readBuffer=this.writeBuffer,this.writeBuffer=e}addPass(e){this.passes.push(e),e.setSize(this._width*this._pixelRatio,this._height*this._pixelRatio)}insertPass(e,t){this.passes.splice(t,0,e),e.setSize(this._width*this._pixelRatio,this._height*this._pixelRatio)}removePass(e){const t=this.passes.indexOf(e);t!==-1&&this.passes.splice(t,1)}isLastEnabledPass(e){for(let t=e+1;t<this.passes.length;t++)if(this.passes[t].enabled)return!1;return!0}render(e){this.timer.update(),e===void 0&&(e=this.timer.getDelta());const t=this.renderer.getRenderTarget();let s=!1;for(let o=0,i=this.passes.length;o<i;o++){const r=this.passes[o];if(r.enabled!==!1){if(r.renderToScreen=this.renderToScreen&&this.isLastEnabledPass(o),r.render(this.renderer,this.writeBuffer,this.readBuffer,e,s),r.needsSwap){if(s){const u=this.renderer.getContext(),l=this.renderer.state.buffers.stencil;l.setFunc(u.NOTEQUAL,1,4294967295),this.copyPass.render(this.renderer,this.writeBuffer,this.readBuffer,e),l.setFunc(u.EQUAL,1,4294967295)}this.swapBuffers()}pt!==void 0&&(r instanceof pt?s=!0:r instanceof vs&&(s=!1))}}this.renderer.setRenderTarget(t)}reset(e){if(e===void 0){const t=this.renderer.getSize(new V);this._pixelRatio=this.renderer.getPixelRatio(),this._width=t.width,this._height=t.height,e=this.renderTarget1.clone(),e.setSize(this._width*this._pixelRatio,this._height*this._pixelRatio)}this.renderTarget1.dispose(),this.renderTarget2.dispose(),this.renderTarget1=e,this.renderTarget2=e.clone(),this.writeBuffer=this.renderTarget1,this.readBuffer=this.renderTarget2}setSize(e,t){this._width=e,this._height=t;const s=this._width*this._pixelRatio,o=this._height*this._pixelRatio;this.renderTarget1.setSize(s,o),this.renderTarget2.setSize(s,o);for(let i=0;i<this.passes.length;i++)this.passes[i].setSize(s,o)}setPixelRatio(e){this._pixelRatio=e,this.setSize(this._width,this._height)}dispose(){this.renderTarget1.dispose(),this.renderTarget2.dispose(),this.copyPass.dispose()}}const Be={name:"OutputShader",uniforms:{tDiffuse:{value:null},toneMappingExposure:{value:1}},vertexShader:`
		precision highp float;

		uniform mat4 modelViewMatrix;
		uniform mat4 projectionMatrix;

		attribute vec3 position;
		attribute vec2 uv;

		varying vec2 vUv;

		void main() {

			vUv = uv;
			gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

		}`,fragmentShader:`

		precision highp float;

		uniform sampler2D tDiffuse;

		#include <tonemapping_pars_fragment>
		#include <colorspace_pars_fragment>

		varying vec2 vUv;

		void main() {

			gl_FragColor = texture2D( tDiffuse, vUv );

			// tone mapping

			#ifdef LINEAR_TONE_MAPPING

				gl_FragColor.rgb = LinearToneMapping( gl_FragColor.rgb );

			#elif defined( REINHARD_TONE_MAPPING )

				gl_FragColor.rgb = ReinhardToneMapping( gl_FragColor.rgb );

			#elif defined( CINEON_TONE_MAPPING )

				gl_FragColor.rgb = CineonToneMapping( gl_FragColor.rgb );

			#elif defined( ACES_FILMIC_TONE_MAPPING )

				gl_FragColor.rgb = ACESFilmicToneMapping( gl_FragColor.rgb );

			#elif defined( AGX_TONE_MAPPING )

				gl_FragColor.rgb = AgXToneMapping( gl_FragColor.rgb );

			#elif defined( NEUTRAL_TONE_MAPPING )

				gl_FragColor.rgb = NeutralToneMapping( gl_FragColor.rgb );

			#elif defined( CUSTOM_TONE_MAPPING )

				gl_FragColor.rgb = CustomToneMapping( gl_FragColor.rgb );

			#endif

			// color space

			#ifdef SRGB_TRANSFER

				gl_FragColor = sRGBTransferOETF( gl_FragColor );

			#endif

		}`};class xs extends ve{constructor(){super(),this.isOutputPass=!0,this.uniforms=Ge.clone(Be.uniforms),this.material=new Lt({name:Be.name,uniforms:this.uniforms,vertexShader:Be.vertexShader,fragmentShader:Be.fragmentShader}),this._fsQuad=new Je(this.material),this._outputColorSpace=null,this._toneMapping=null}render(e,t,s){this.uniforms.tDiffuse.value=s.texture,this.uniforms.toneMappingExposure.value=e.toneMappingExposure,(this._outputColorSpace!==e.outputColorSpace||this._toneMapping!==e.toneMapping)&&(this._outputColorSpace=e.outputColorSpace,this._toneMapping=e.toneMapping,this.material.defines={},Gt.getTransfer(this._outputColorSpace)===Ut&&(this.material.defines.SRGB_TRANSFER=""),this._toneMapping===Ht?this.material.defines.LINEAR_TONE_MAPPING="":this._toneMapping===kt?this.material.defines.REINHARD_TONE_MAPPING="":this._toneMapping===Qt?this.material.defines.CINEON_TONE_MAPPING="":this._toneMapping===Wt?this.material.defines.ACES_FILMIC_TONE_MAPPING="":this._toneMapping===Vt?this.material.defines.AGX_TONE_MAPPING="":this._toneMapping===$t?this.material.defines.NEUTRAL_TONE_MAPPING="":this._toneMapping===Kt&&(this.material.defines.CUSTOM_TONE_MAPPING=""),this.material.needsUpdate=!0),this.renderToScreen===!0?(e.setRenderTarget(null),this._fsQuad.render(e)):(e.setRenderTarget(t),this.clear&&e.clear(e.autoClearColor,e.autoClearDepth,e.autoClearStencil),this._fsQuad.render(e))}dispose(){this.material.dispose(),this._fsQuad.dispose()}}class Ss extends ve{constructor(e,t,s=null,o=null,i=null){super(),this.scene=e,this.camera=t,this.overrideMaterial=s,this.clearColor=o,this.clearAlpha=i,this.clear=!0,this.clearDepth=!1,this.needsSwap=!1,this.isRenderPass=!0,this._oldClearColor=new H}render(e,t,s){const o=e.autoClear;e.autoClear=!1;let i,r;this.overrideMaterial!==null&&(r=this.scene.overrideMaterial,this.scene.overrideMaterial=this.overrideMaterial),this.clearColor!==null&&(e.getClearColor(this._oldClearColor),e.setClearColor(this.clearColor,e.getClearAlpha())),this.clearAlpha!==null&&(i=e.getClearAlpha(),e.setClearAlpha(this.clearAlpha)),this.clearDepth==!0&&e.clearDepth(),e.setRenderTarget(this.renderToScreen?null:s),this.clear===!0&&e.clear(e.autoClearColor,e.autoClearDepth,e.autoClearStencil),e.render(this.scene,this.camera),this.clearColor!==null&&e.setClearColor(this._oldClearColor),this.clearAlpha!==null&&e.setClearAlpha(i),this.overrideMaterial!==null&&(this.scene.overrideMaterial=r),e.autoClear=o}}const Ts={uniforms:{tDiffuse:{value:null},luminosityThreshold:{value:1},smoothWidth:{value:1},defaultColor:{value:new H(0)},defaultOpacity:{value:0}},vertexShader:`

		varying vec2 vUv;

		void main() {

			vUv = uv;

			gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

		}`,fragmentShader:`

		uniform sampler2D tDiffuse;
		uniform vec3 defaultColor;
		uniform float defaultOpacity;
		uniform float luminosityThreshold;
		uniform float smoothWidth;

		varying vec2 vUv;

		void main() {

			vec4 texel = texture2D( tDiffuse, vUv );

			float v = luminance( texel.xyz );

			vec4 outputColor = vec4( defaultColor.rgb, defaultOpacity );

			float alpha = smoothstep( luminosityThreshold, luminosityThreshold + smoothWidth, v );

			gl_FragColor = mix( outputColor, texel, alpha );

		}`};class be extends ve{constructor(e,t=1,s,o){super(),this.strength=t,this.radius=s,this.threshold=o,this.resolution=e!==void 0?new V(e.x,e.y):new V(256,256),this.clearColor=new H(0,0,0),this.needsSwap=!1,this.renderTargetsHorizontal=[],this.renderTargetsVertical=[],this.nMips=5;let i=Math.round(this.resolution.x/2),r=Math.round(this.resolution.y/2);this.renderTargetBright=new ye(i,r,{type:Ae,depthBuffer:!1}),this.renderTargetBright.texture.name="UnrealBloomPass.bright",this.renderTargetBright.texture.generateMipmaps=!1;for(let c=0;c<this.nMips;c++){const E=new ye(i,r,{type:Ae,depthBuffer:!1});E.texture.name="UnrealBloomPass.h"+c,E.texture.generateMipmaps=!1,this.renderTargetsHorizontal.push(E);const P=new ye(i,r,{type:Ae,depthBuffer:!1});P.texture.name="UnrealBloomPass.v"+c,P.texture.generateMipmaps=!1,this.renderTargetsVertical.push(P),i=Math.round(i/2),r=Math.round(r/2)}const u=Ts;this.highPassUniforms=Ge.clone(u.uniforms),this.highPassUniforms.luminosityThreshold.value=o,this.highPassUniforms.smoothWidth.value=.01,this.materialHighPassFilter=new ge({uniforms:this.highPassUniforms,vertexShader:u.vertexShader,fragmentShader:u.fragmentShader}),this.separableBlurMaterials=[];const l=[6,10,14,18,22];i=Math.round(this.resolution.x/2),r=Math.round(this.resolution.y/2);for(let c=0;c<this.nMips;c++)this.separableBlurMaterials.push(this._getSeparableBlurMaterial(l[c])),this.separableBlurMaterials[c].uniforms.invSize.value=new V(1/i,1/r),i=Math.round(i/2),r=Math.round(r/2);this.compositeMaterial=this._getCompositeMaterial(this.nMips),this.compositeMaterial.uniforms.blurTexture1.value=this.renderTargetsVertical[0].texture,this.compositeMaterial.uniforms.blurTexture2.value=this.renderTargetsVertical[1].texture,this.compositeMaterial.uniforms.blurTexture3.value=this.renderTargetsVertical[2].texture,this.compositeMaterial.uniforms.blurTexture4.value=this.renderTargetsVertical[3].texture,this.compositeMaterial.uniforms.blurTexture5.value=this.renderTargetsVertical[4].texture,this.compositeMaterial.uniforms.bloomStrength.value=t,this.compositeMaterial.uniforms.bloomRadius.value=.1;const d=[1,.8,.6,.4,.2];this.compositeMaterial.uniforms.bloomFactors.value=d,this.bloomTintColors=[new $(1,1,1),new $(1,1,1),new $(1,1,1),new $(1,1,1),new $(1,1,1)],this.compositeMaterial.uniforms.bloomTintColors.value=this.bloomTintColors,this.copyUniforms=Ge.clone(Le.uniforms),this.blendMaterial=new ge({uniforms:this.copyUniforms,vertexShader:Le.vertexShader,fragmentShader:Le.fragmentShader,premultipliedAlpha:!0,blending:Ue,depthTest:!1,depthWrite:!1,transparent:!0}),this._oldClearColor=new H,this._oldClearAlpha=1,this._basic=new Xe,this._fsQuad=new Je(null)}dispose(){for(let e=0;e<this.renderTargetsHorizontal.length;e++)this.renderTargetsHorizontal[e].dispose();for(let e=0;e<this.renderTargetsVertical.length;e++)this.renderTargetsVertical[e].dispose();this.renderTargetBright.dispose();for(let e=0;e<this.separableBlurMaterials.length;e++)this.separableBlurMaterials[e].dispose();this.compositeMaterial.dispose(),this.blendMaterial.dispose(),this._basic.dispose(),this._fsQuad.dispose()}setSize(e,t){let s=Math.round(e/2),o=Math.round(t/2);this.renderTargetBright.setSize(s,o);for(let i=0;i<this.nMips;i++)this.renderTargetsHorizontal[i].setSize(s,o),this.renderTargetsVertical[i].setSize(s,o),this.separableBlurMaterials[i].uniforms.invSize.value=new V(1/s,1/o),s=Math.round(s/2),o=Math.round(o/2)}render(e,t,s,o,i){e.getClearColor(this._oldClearColor),this._oldClearAlpha=e.getClearAlpha();const r=e.autoClear;e.autoClear=!1,e.setClearColor(this.clearColor,0),i&&e.state.buffers.stencil.setTest(!1),this.renderToScreen&&(this._fsQuad.material=this._basic,this._basic.map=s.texture,e.setRenderTarget(null),e.clear(),this._fsQuad.render(e)),this.highPassUniforms.tDiffuse.value=s.texture,this.highPassUniforms.luminosityThreshold.value=this.threshold,this._fsQuad.material=this.materialHighPassFilter,e.setRenderTarget(this.renderTargetBright),e.clear(),this._fsQuad.render(e);let u=this.renderTargetBright;for(let l=0;l<this.nMips;l++)this._fsQuad.material=this.separableBlurMaterials[l],this.separableBlurMaterials[l].uniforms.colorTexture.value=u.texture,this.separableBlurMaterials[l].uniforms.direction.value=be.BlurDirectionX,e.setRenderTarget(this.renderTargetsHorizontal[l]),e.clear(),this._fsQuad.render(e),this.separableBlurMaterials[l].uniforms.colorTexture.value=this.renderTargetsHorizontal[l].texture,this.separableBlurMaterials[l].uniforms.direction.value=be.BlurDirectionY,e.setRenderTarget(this.renderTargetsVertical[l]),e.clear(),this._fsQuad.render(e),u=this.renderTargetsVertical[l];this._fsQuad.material=this.compositeMaterial,this.compositeMaterial.uniforms.bloomStrength.value=this.strength,this.compositeMaterial.uniforms.bloomRadius.value=this.radius,this.compositeMaterial.uniforms.bloomTintColors.value=this.bloomTintColors,e.setRenderTarget(this.renderTargetsHorizontal[0]),e.clear(),this._fsQuad.render(e),this._fsQuad.material=this.blendMaterial,this.copyUniforms.tDiffuse.value=this.renderTargetsHorizontal[0].texture,i&&e.state.buffers.stencil.setTest(!0),this.renderToScreen?(e.setRenderTarget(null),this._fsQuad.render(e)):(e.setRenderTarget(s),this._fsQuad.render(e)),e.setClearColor(this._oldClearColor,this._oldClearAlpha),e.autoClear=r}_getSeparableBlurMaterial(e){const t=[],s=e/3;for(let r=0;r<e;r++)t.push(.39894*Math.exp(-.5*r*r/(s*s))/s);const o=[],i=[];for(let r=1;r<e;r+=2){const u=t[r],l=r+1<e?t[r+1]:0,d=u+l;o.push((r*u+(r+1)*l)/d),i.push(d)}return new ge({defines:{KERNEL_PAIRS:o.length},uniforms:{colorTexture:{value:null},invSize:{value:new V(.5,.5)},direction:{value:new V(.5,.5)},centerWeight:{value:t[0]},gaussianOffsets:{value:o},gaussianWeights:{value:i}},vertexShader:`

				varying vec2 vUv;

				void main() {

					vUv = uv;
					gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

				}`,fragmentShader:`

				#include <common>

				varying vec2 vUv;

				uniform sampler2D colorTexture;
				uniform vec2 invSize;
				uniform vec2 direction;
				uniform float centerWeight;
				uniform float gaussianOffsets[KERNEL_PAIRS];
				uniform float gaussianWeights[KERNEL_PAIRS];

				void main() {

					vec3 diffuseSum = texture2D( colorTexture, vUv ).rgb * centerWeight;

					for ( int i = 0; i < KERNEL_PAIRS; i ++ ) {

						vec2 uvOffset = direction * invSize * gaussianOffsets[ i ];
						vec3 sample1 = texture2D( colorTexture, vUv + uvOffset ).rgb;
						vec3 sample2 = texture2D( colorTexture, vUv - uvOffset ).rgb;
						diffuseSum += ( sample1 + sample2 ) * gaussianWeights[ i ];

					}

					gl_FragColor = vec4( diffuseSum, 1.0 );

				}`})}_getCompositeMaterial(e){return new ge({defines:{NUM_MIPS:e},uniforms:{blurTexture1:{value:null},blurTexture2:{value:null},blurTexture3:{value:null},blurTexture4:{value:null},blurTexture5:{value:null},bloomStrength:{value:1},bloomFactors:{value:null},bloomTintColors:{value:null},bloomRadius:{value:0}},vertexShader:`

				varying vec2 vUv;

				void main() {

					vUv = uv;
					gl_Position = projectionMatrix * modelViewMatrix * vec4( position, 1.0 );

				}`,fragmentShader:`

				varying vec2 vUv;

				uniform sampler2D blurTexture1;
				uniform sampler2D blurTexture2;
				uniform sampler2D blurTexture3;
				uniform sampler2D blurTexture4;
				uniform sampler2D blurTexture5;
				uniform float bloomStrength;
				uniform float bloomRadius;
				uniform float bloomFactors[NUM_MIPS];
				uniform vec3 bloomTintColors[NUM_MIPS];

				float lerpBloomFactor( const in float factor ) {

					float mirrorFactor = 1.2 - factor;
					return mix( factor, mirrorFactor, bloomRadius );

				}

				void main() {

					// 3.0 for backwards compatibility with previous alpha-based intensity
					vec3 bloom = 3.0 * bloomStrength * (
						lerpBloomFactor( bloomFactors[ 0 ] ) * bloomTintColors[ 0 ] * texture2D( blurTexture1, vUv ).rgb +
						lerpBloomFactor( bloomFactors[ 1 ] ) * bloomTintColors[ 1 ] * texture2D( blurTexture2, vUv ).rgb +
						lerpBloomFactor( bloomFactors[ 2 ] ) * bloomTintColors[ 2 ] * texture2D( blurTexture3, vUv ).rgb +
						lerpBloomFactor( bloomFactors[ 3 ] ) * bloomTintColors[ 3 ] * texture2D( blurTexture4, vUv ).rgb +
						lerpBloomFactor( bloomFactors[ 4 ] ) * bloomTintColors[ 4 ] * texture2D( blurTexture5, vUv ).rgb
					);

					float bloomAlpha = max( bloom.r, max( bloom.g, bloom.b ) );
					gl_FragColor = vec4( bloom, bloomAlpha );

				}`})}}be.BlurDirectionX=new V(1,0);be.BlurDirectionY=new V(0,1);const yt="#151030",At=-32;function Ze({w:a,d:e=a,top:t,depth:s,fade:o=s,x:i,z:r,color:u="#8d79b3",topColor:l="#e6dbf2"}){const d=new x(a,s,e,1,Math.max(1,Math.ceil(s/2))).toNonIndexed();d.translate(i,t-s/2,r);const c=d.getAttribute("position"),E=d.getAttribute("normal"),P=new Float32Array(c.count*3),_=new Float32Array(c.count),z=new H(u),y=new H(l);for(let f=0;f<c.count;f++){const S=E.getY(f)>.5?y:z;P.set([S.r,S.g,S.b],f*3),_[f]=E.getY(f)>.5?0:Math.min(1,Math.max(0,(t-c.getY(f))/o))**.8}return d.setAttribute("color",new te(P,3)),d.setAttribute("fade",new te(_,1)),d}function _s(a){const e=new H(yt);return a.onBeforeCompile=t=>{t.uniforms.uNight={value:e},t.vertexShader=t.vertexShader.replace("#include <common>",`#include <common>
attribute float fade;
varying float vFade;`).replace("#include <begin_vertex>",`#include <begin_vertex>
  vFade = fade;`),t.fragmentShader=t.fragmentShader.replace("#include <common>",`#include <common>
uniform vec3 uNight;
varying float vFade;`).replace("#include <opaque_fragment>",`outgoingLight = mix(outgoingLight, uNight, vFade);
#include <opaque_fragment>`)},a}function q(a,e,t){const s=document.createElement("canvas");s.width=a,s.height=e,t(s.getContext("2d"));const o=new jt(s);return o.colorSpace=xt,o}function Cs(){return q(64,64,a=>{const e=a.createRadialGradient(32,32,0,32,32,32);e.addColorStop(0,"rgba(255,255,255,0.9)"),e.addColorStop(.25,"rgba(255,255,255,0.35)"),e.addColorStop(1,"rgba(255,255,255,0)"),a.fillStyle=e,a.fillRect(0,0,64,64)})}function Et(a,e,{font:t,bg:s,fg:o},i){const r=document.createElement("canvas").getContext("2d");r.font=t;const u=Math.ceil(r.measureText(e).width)+48,l=a(q(u,72,c=>{c.fillStyle=s,c.beginPath(),c.roundRect(0,0,u,72,36),c.fill(),c.font=t,c.fillStyle=o,c.textBaseline="middle",c.fillText(e,24,38)})),d=new St(a(new Tt({map:l,transparent:!0,depthWrite:!1})));return d.scale.set(i*u/72,i,1),d}function ce(a){let e=a;return()=>(e=e*16807%2147483647)/2147483647}const ys=[[[1.3,1.3],[-1.3,1.3]],[[6.3,1.3],[3.7,1.3]],[[6.3,6.3],[6.3,3.7]],[[11.3,1.3],[8.7,-1.3]]],As="#e6dbf2",Es=[-1.05,-1.05],R={x:-1.6,z:-5.4,w:2.2,top:1},Ps={center:[4,-3,1],radius:26,count:260},Rs=.7,Is=.25,je=50,Fe=140,Ns=-9,mt=17,Pt="ui-monospace, Menlo, Consolas, monospace";function Os(a,e,t){const{scene:s,own:o,lambert:i,basic:r,glow:u,place:l,pillarMat:d}=a,c=p=>l(new m(o(Ze(p)),d),s),E=p=>e.find(g=>g.island===p)?.color??As,P=o(new x(.05,.75,.05)),_=o(new Ce(.065,.065,.34,10)),z=i({color:"#3b3350"});Ct.forEach(([,p],g)=>{const v=r({color:E(g)});for(const[C,N]of ys[g])l(new m(P,z),s,C,p+.375,N),l(new m(_,v),s,C,p+.92,N),u(E(g),.9,s).position.set(C,p+.95,N)});const[y,f]=Es;c({w:.22,top:1.1,depth:1.1,x:y,z:f,color:"#7a5244",topColor:"#8e6050"}),l(new m(o(new x(.12,.5,.12)),i({color:"#7a5244"})),s,y+.2,1.05,f).rotation.z=-.6;{const g=["#ffc7dc","#ffb0cc","#ffe0ec","#f7a1c0"].map(G=>new H(G)),v=l(o(new Yt(o(new x(1,1,1)),i({color:"#ffffff",emissive:"#ff9cc0",emissiveIntensity:.12}),46)),s),C=ce(3),N=new qt;for(let G=0;G<46;G++){const Ie=C()*Math.PI*2,Ne=Math.sqrt(C())*.8,Ve=1.45+(C()-.4)*.6,ae=.18+C()*.16;v.setMatrixAt(G,N.makeScale(ae,ae,ae).setPosition(y+Math.cos(Ie)*Ne,Ve,f+Math.sin(Ie)*Ne)),v.setColorAt(G,g[G%g.length])}}const S=ce(5),M=Array.from({length:je},()=>S()*100),O=gt(o,je,o(new $e({color:"#ffc2d8",size:4,sizeAttenuation:!1,transparent:!0,opacity:.9})));s.add(O.points),c({w:.35,top:2.15,depth:2.15,x:4,z:-1.1,color:"#9a86c0"}),c({w:.35,top:2.15,depth:2.15,x:6,z:-1.1,color:"#9a86c0"}),c({w:2.35,d:.35,top:2.32,depth:.35,x:5,z:-1.1,color:"#b39ad6",topColor:"#efe4fa"});const k=o(Fs());k.wrapT=Xt,l(new m(o(new ne(1.62,1.95)),r({map:k,transparent:!0,opacity:.32,side:Zt,depthWrite:!1})),s,5,.99,-1.1),c({w:.8,top:-1.2,depth:.8,x:3.95,z:4,color:"#9a86c0"}),l(new m(o(new nt(.42,1.4,4)),i({color:"#7ee6c0"})),s,3.95,-.5,4).rotation.y=Math.PI/4;{const p=l(new Y,s,3.85,-2,5.95);p.rotation.y=.9,l(new m(o(new x(.05,.95,.05)),i({color:"#2b2633"})),p,0,.47,0),l(new m(o(new Jt(.3,.045,10,36)),r({color:"#fff6ea"})),p,0,1.2,0),l(new m(o(new x(.13,.24,.02)),i({color:"#1b1a22"})),p,0,1.2,0),u("#fff1dc",1.4,p).position.set(0,1.2,0)}c({w:1,top:2.9,depth:.9,x:10.95,z:-1,color:"#9a86c0"}),l(new m(o(new nt(.85,.55,4)),i({color:"#bfe4f7"})),s,10.95,3.17,-1).rotation.y=Math.PI/4,l(new m(o(new x(.3,.5,.02)),r({color:"#ffd99a"})),s,10.95,2.3,-.49),l(new m(o(new x(1.2,.24,.34)),i({color:"#efe7f7"})),s,9,2.12,1.25);{const p=o(new x(.03,.2,.03)),g=o(new x(.1,.1,.1)),v=i({color:"#6fbf73"});["#ffffff","#ffe27a","#bfe0ff","#ffc4d8","#ffffff"].forEach((C,N)=>{const G=8.55+N*.22;l(new m(p,v),s,G,2.33,1.25),l(new m(g,i({color:C,emissive:C,emissiveIntensity:.2})),s,G,2.46,1.25)})}const D=l(Et(o,"temperature 0.7",{font:`600 44px ${Pt}`,bg:"rgba(20,16,40,0.35)",fg:"rgba(243,238,255,0.6)"},.16),s,le[0],le[1]+.75,le[2]+.35);D.material.depthTest=!1,D.renderOrder=10,c({w:R.w,top:R.top,depth:R.top-At,fade:12,x:R.x,z:R.z,color:"#6f5d99",topColor:"#cfc0e6"});const I=o(Ds()),fe=r({map:I,transparent:!0,depthWrite:!1}),ue=o(new ne(R.w-.2,8)),se=R.w/2+.011;l(new m(ue,fe),s,R.x,R.top-4.3,R.z+se),l(new m(ue,fe),s,R.x+se,R.top-4.3,R.z).rotation.y=Math.PI/2,l(new m(o(new ne(1.5,.75)),r({map:o(zs())})),s,R.x,R.top-.22,R.z+se+.01);const L=l(new Y,s,-4.4,-3,4.2);L.scale.setScalar(.8),L.rotation.y=Math.PI/4,l(new m(o(new x(1.5,2.1,.28)),i({color:"#8a7fa6"})),L),l(new m(o(new x(1.7,.2,.4)),i({color:"#a497c0"})),L,0,1.12,0);const B=i({color:"#6c6088"});l(new m(o(new x(.6,.4,.5)),B),L,.2,-1.3,.05),l(new m(o(new x(.3,.3,.3)),B),L,-.35,-1.75,0),l(new m(o(new ne(1.36,1.9)),r({map:o(Ls()),transparent:!0})),L,0,0,.145);const Me=Bs(),xe=(p,g)=>Me.filter(v=>v!==p).sort((v,C)=>v.distanceToSquared(p)-C.distanceToSquared(p)).slice(0,g),ke=Me.flatMap(p=>xe(p,2).flatMap(g=>p.distanceTo(g)<5?[p,g]:[]));s.add(new _t(o(new we().setFromPoints(Me)),o(new $e({color:"#d8d0ff",size:2.2,sizeAttenuation:!1,transparent:!0,opacity:.45})))),s.add(new lt(o(new we().setFromPoints(ke)),o(new ct({color:"#8f84c9",transparent:!0,opacity:.05}))));const Se=new $(...rs),Ee=o(new ct({color:t,transparent:!0,opacity:0}));s.add(new lt(o(new we().setFromPoints(xe(Se,5).flatMap(p=>[Se,p]))),Ee));const K=u(t,0,s);K.position.copy(Se);const oe=[...e.map(p=>p.color),"#ffffff","#bcb2ff"].map(p=>new H(p)),he=ce(29),Pe=Array.from({length:Fe},(p,g)=>({x:-6+he()*22,y:he()*mt,z:-6+he()*15,speed:.12+he()*.3,color:oe[g%oe.length]})),ie=gt(o,Fe,o(new $e({size:2.5,sizeAttenuation:!1,vertexColors:!0,transparent:!0,opacity:.35,blending:Ue,depthWrite:!1}))),de=new Float32Array(Fe*3);Pe.forEach((p,g)=>de.set(p.color.toArray(),g*3)),ie.points.geometry.setAttribute("color",new te(de,3)),s.add(ie.points);const pe=o(Gs()),J=o(new ne(30,30)),Re=[{y:-5.2,color:"#7d6fb8",opacity:.45,spin:.01},{y:-6.6,color:"#4a3d80",opacity:.7,spin:-.006}].map(p=>{const g=l(new m(J,r({map:pe,color:p.color,transparent:!0,opacity:p.opacity,depthWrite:!1})),s,5,p.y,1);return g.rotation.x=-Math.PI/2,{m:g,spin:p.spin}}),Qe=o(new x(.35,.35,.35)),We=[[-2.6,1.4,2.4,"#f1c9d9"],[7.7,2.8,-2.4,"#bfe4f7"],[8.4,-1.6,4.2,"#c7f0b3"],[1.6,2.6,-2.6,"#ffd2bf"],[2.2,-2.2,3.4,"#b39ad6"],[12.6,.2,3.2,"#ffd59a"]].map(([p,g,v,C],N)=>({m:l(new m(Qe,i({color:C})),s,p,g,v),y:g,phase:N*1.7}));return{update(p,g){k.offset.y=g*.04%1,D.visible=p.temperature>0,D.material.opacity=p.temperature,K.scale.setScalar(Rs*p.embedding*(1+Math.sin(g*2)*.15)),Ee.opacity=Is*p.embedding,M.forEach((v,C)=>{const N=(g*.12+v)%1;O.position.set([y+Math.sin(v*3)*.9+N*1.6+Math.sin(g+v)*.15,1.6-N*2.4,f+Math.cos(v*5)*.9+N*.8],C*3)}),O.changed(),Pe.forEach((v,C)=>ie.position.set([v.x,Ns+(v.y+v.speed*g)%mt,v.z],C*3)),ie.changed();for(const v of Re)v.m.rotation.z=g*v.spin;L.position.y=-3+Math.sin(g*.7)*.1;for(const v of We)v.m.position.y=v.y+Math.sin(g*.8+v.phase)*.15},setParticles(p){O.points.geometry.setDrawRange(0,Math.round(je*p)),ie.points.geometry.setDrawRange(0,Math.round(Fe*p))}}}function gt(a,e,t){const s=new Float32Array(e*3),o=a(new we);o.setAttribute("position",new te(s,3));const i=new _t(o,t);return i.frustumCulled=!1,{points:i,position:s,changed:()=>o.getAttribute("position").needsUpdate=!0}}function Bs(){const{center:a,radius:e,count:t}=Ps,s=ce(17),o=[];for(;o.length<t;){const i=new $(s()*2-1,s()*2-1,s()*2-1);i.lengthSq()>1||(i.multiplyScalar(e).add(new $(...a)),!(i.x+i.z-(a[0]+a[2])>-9)&&o.push(i))}return o}function Fs(){const a=["<bos>","下周","考试","了","，","有点","紧张","。","加油","ファイト","です","！","真乃","说","<eos>","▁mem","ory","▁you","了解","…"],e=["#ffbad6","#ffd59a","#b9f0c6","#bfe0ff","#e2c8ff","#ffcbb8"];return q(256,512,t=>{t.fillStyle="rgba(170,200,255,0.12)",t.fillRect(0,0,256,512),t.font=`600 22px ${Pt}, sans-serif`,t.textBaseline="middle";let s=0;for(let o=10;o<512;o+=34){let i=10;for(;i<240;){const r=a[s%a.length],u=t.measureText(r).width+12;if(i+u>248)break;t.fillStyle=e[s*7%e.length],t.globalAlpha=.85,t.beginPath(),t.roundRect(i,o,u,26,5),t.fill(),t.globalAlpha=1,t.fillStyle="#1e1838",t.fillText(r,i+6,o+14),i+=u+5,s++}s+=3}})}function Ds(){const a=q(64,256,e=>{const t=ce(5);for(let s=6;s<256;s+=14)for(let o=5;o<60;o+=11){const i=t()<.28;e.fillStyle=i?`rgba(255,${200+Math.floor(t()*40)},150,${.35+t()*.3})`:"rgba(40,32,72,0.45)",e.fillRect(o,s,7,8)}});return a.magFilter=es,a}function zs(){return q(256,128,a=>{a.fillStyle="#1c2a4a",a.beginPath(),a.roundRect(0,0,256,128,14),a.fill(),a.fillStyle="#ffffff",a.textAlign="center",a.font="800 70px Georgia, 'Times New Roman', serif",a.fillText("283",128,78),a.font="600 18px ui-sans-serif, system-ui, sans-serif",a.fillStyle="#cfe0ff",a.fillText("P R O D U C T I O N",128,110)})}function Ls(){return q(300,420,a=>{a.fillStyle="#6e6390",a.textAlign="center",a.font="700 40px Georgia, 'Times New Roman', serif",["ATTENTION","IS ALL","YOU NEED"].forEach((e,t)=>a.fillText(e,150,110+t*62)),a.font="italic 22px Georgia, serif",a.fillText("— 1706.03762 —",150,330),a.strokeStyle="#7a6f9c",a.lineWidth=3,a.strokeRect(18,18,264,384)})}function Gs(){return q(512,512,a=>{const e=ce(23);for(let t=0;t<120;t++){const s=e()*Math.PI*2,o=Math.sqrt(e())*200,i=256+Math.cos(s)*o,r=256+Math.sin(s)*o,u=30+e()*70,l=a.createRadialGradient(i,r,0,i,r,u);l.addColorStop(0,`rgba(255,255,255,${(.22*(1-o/220)).toFixed(3)})`),l.addColorStop(1,"rgba(255,255,255,0)"),a.fillStyle=l,a.fillRect(i-u,r-u,u*2,u*2)}})}const Us=3e4,Hs=.86,ks=.78,Qs=.18,De=50,wt=2048,ze=14,Ye={strength:.5,radius:.55,threshold:.94},Ws=.3,Vs=.05,$s=.08,Ks=.08,bt="#6ff0d0",js=.6,Ys="#e0e0e0",He="#1c2a4a",qs=7,Xs=1.4,qe=new Map;function Zs(a){let e=qe.get(a);return e||(e=fetch(a,{signal:AbortSignal.timeout(Us)}).then(t=>{if(!t.ok)throw new Error(`体素文件 ${t.status}`);return t.json()}).then(t=>eo(Js(t))).catch(t=>{throw qe.delete(a),t}),qe.set(a,e)),e}function Js(a){const e=a;if(!(!!e&&Array.isArray(e.size)&&e.size.length===3&&e.size.every(s=>Number.isInteger(s)&&s>0)&&typeof e.front=="number"&&e.front>0&&Array.isArray(e.palette)&&Array.isArray(e.voxels)&&e.voxels.length%4===0))throw new Error("体素文件的格式不对");return e}const vt=[{n:[1,0,0],corners:[[1,0,0],[1,1,0],[1,1,1],[1,0,1]],shade:1},{n:[-1,0,0],corners:[[0,0,0],[0,0,1],[0,1,1],[0,1,0]],shade:1},{n:[0,1,0],corners:[[0,1,0],[0,1,1],[1,1,1],[1,1,0]],shade:Hs},{n:[0,-1,0],corners:[[0,0,0],[1,0,0],[1,0,1],[0,0,1]],shade:ks},{n:[0,0,1],corners:[[0,0,1],[1,0,1],[1,1,1],[0,1,1]],shade:1},{n:[0,0,-1],corners:[[0,0,0],[0,1,0],[1,1,0],[1,0,0]],shade:1}];function eo(a){const[e,t,s]=a.size,o=ps/a.front,i=new Uint8Array(e*t*s),r=[],u=(f,S,M)=>f>=0&&S>=0&&M>=0&&f<e&&S<t&&M<s;for(let f=0;f<a.voxels.length;f+=4){const[S,M,O,k]=[a.voxels[f],a.voxels[f+1],a.voxels[f+2],a.voxels[f+3]];!u(S,M,O)||!a.palette[k]||(i[S+e*(M+t*O)]=1,r.push(S,M,O,k))}const l=(f,S,M)=>u(f,S,M)&&i[f+e*(S+t*M)]===1,d=a.palette.map(f=>new H(f).toArray());let c=0;for(let f=0;f<r.length;f+=4)for(const S of vt)l(r[f]+S.n[0],r[f+1]+S.n[1],r[f+2]+S.n[2])||c++;const E=new Float32Array(c*12),P=new Int8Array(c*12),_=new Float32Array(c*12),z=new Uint32Array(c*6);let y=0;for(let f=0;f<r.length;f+=4){const[S,M,O,k]=[r[f],r[f+1],r[f+2],r[f+3]],D=d[k];for(const I of vt)l(S+I.n[0],M+I.n[1],O+I.n[2])||(I.corners.forEach(([fe,ue,se],L)=>{const B=(y*4+L)*3;E[B]=(S+fe-e/2)*o,E[B+1]=(M+ue)*o,E[B+2]=(O+se-s/2)*o,P[B]=I.n[0]*127,P[B+1]=I.n[1]*127,P[B+2]=I.n[2]*127,_[B]=D[0]*I.shade,_[B+1]=D[1]*I.shade,_[B+2]=D[2]*I.shade}),z.set([y*4,y*4+1,y*4+2,y*4,y*4+2,y*4+3],y*6),y++)}return{position:E,normal:P,color:_,index:z}}async function fo(a,e,t,s){const o=t.map(n=>n.voxels?Zs(n.voxels):Promise.reject(new Error("没有体素文件")));let i=!1;const r=n=>Math.min(window.devicePixelRatio||1,n.dprCap),u=new ts({canvas:a,antialias:!0});u.outputColorSpace=xt,await _e();const l=[],d=n=>(l.push(n),n),c=new ss,E=d(Cs()),P={scene:c,own:d,lambert:n=>d(new ft(n)),basic:n=>d(new Xe(n)),glow(n,h,w){const T=new St(d(new Tt({map:E,color:n,blending:Ue,depthWrite:!1,transparent:!0})));return T.scale.setScalar(h),w.add(T),T},place(n,h,w=0,T=0,U=0){return n.position.set(w,T,U),h.add(n),n},pillarMat:_s(d(new ft({vertexColors:!0})))},{lambert:_,basic:z,glow:y,place:f,pillarMat:S}=P;c.add(new os(13222655,2760509,1.5));const M=new ut(16769740,2.2);M.position.set(2,10,7),M.target.position.set(5,0,1),M.shadow.mapSize.set(wt,wt),Object.assign(M.shadow.camera,{left:-ze,right:ze,top:ze,bottom:-ze,near:.5,far:50}),M.shadow.bias=-5e-4,M.shadow.normalBias=.02,c.add(M,M.target);const O=new ut(9075967,.6);O.position.set(8,2,-2),c.add(O);let k=0,D=null;const I=n=>{D?.dispose(),D=oo(n),c.background=D,k=n};Ct.forEach(([n,h,w])=>{c.add(new m(d(Ze({w:dt,top:h,depth:h-At,fade:10+h,x:n,z:w})),S)),c.add(new m(d(Ze({w:dt+.12,top:h-.12,depth:.35,x:n,z:w,color:"#a893c9",topColor:"#cdbde6"})),S))});const fe=d(new x(.9,.04,.9)),ue=d(io()),se=d(new ne(.84,.84)),L=d(new Xe({map:ue,transparent:!0,depthWrite:!1})),B=so(_({vertexColors:!0})),Me=d(new x(.55,.55,.55)),xe=new Map,ke=n=>h=>{if(i)return null;const w=new m(d(to(h)),B);return w.castShadow=!0,n.add(w),null},Se=(n,h)=>()=>{if(i)return n;const w=new m(Me,_({color:n.color,emissive:n.color,emissiveIntensity:.25}));w.castShadow=!0,w.position.y=.275,h.add(w);const T=Et(d,n.name,{font:`600 44px ${s}`,bg:"rgba(20,16,40,0.78)",fg:"#f3eeff"},.22);return T.position.y=.95,h.add(T),n},Ee=t.map((n,h)=>{const[w,T,U]=ns[n.island],X=new m(fe,_({color:n.color,emissive:n.color,emissiveIntensity:.3}));X.position.set(w,T+.02,U),c.add(X);const j=new Y;j.position.set(w,T+.04,U),c.add(j);const W=new Y;W.rotation.order="YXZ",j.add(W),xe.set(n.island,W);const Z=new m(se,L);return Z.rotation.x=-Math.PI/2,Z.position.y=.005,j.add(Z),o[h].then(ke(W),Se(n,W))});await _e();const K=new H(t.find(n=>n.island===0)?.color??"#ffffff"),oe=f(new Y,c,...ls);oe.rotation.set(-.12,Math.PI/4,0),f(new m(d(new x(1.05,2.05,.12)),_({color:"#d9d6e2"})),oe),f(new m(d(new ne(.95,1.92)),z({map:d(ao(K)),color:Ys})),oe,0,0,.065);const he=y("#ffd6e8",3.2,oe),Pe=d(new x(Ke,Ke,Ke)),ie=z({color:K}),de=n=>{const h=f(new Y,n),w=f(new m(Pe,ie),h);return{g:h,cube:w,glow:y(K,1.3,h)}},pe=f(new Y,c),J=f(new Y,pe),Re=_({color:He,emissive:He,emissiveIntensity:.6});f(new m(d(new x(.56,.34,.12)),Re),J),f(new m(d(new x(.12,.12,.12)),Re),J,.16,-.2,0);const Qe=d(new x(.07,.07,.04)),We=z({color:"#ffffff"});for(const n of[-.14,0,.14])f(new m(Qe,We),J,n,0,.07);y("#a9c6f5",1.4,J);const p=de(pe),g=d(new Ce(.25,.25,.14,28)),v=d(new Ce(.27,.27,.04,28)),C=d(new x(.06,.035,.02)),N=_({color:"#cdbde6"}),G=_({color:"#efe6fa"}),Ie=new H(bt),Ne=cs.map((n,h)=>{const w=f(new Y,c,...n),T=[0,1,2].map(X=>{const j=.09+X*.17;f(new m(g,N),w,0,j,0);const W=z({color:bt}),Z=f(new m(C,W),w,Math.SQRT1_2*.25,j,Math.SQRT1_2*.25);return Z.rotation.y=Math.PI/4,W});f(new m(v,G),w,0,ds,0);const U=de(c);return U.g.position.set(...Oe(h)),{leds:T,block:U}}),Ve=new Map([1,2,3].map(n=>[n,de(c)]));f(new m(d(new Ce(.7,.7,6,32)),_({color:"#6f5f96"})),c,le[0],le[1]-3.25,le[2]);const ae=f(new Y,c,...le),et=()=>_({color:"#d9cbe8",emissive:K,emissiveIntensity:0}),Rt=d(new x(.98,.25,.98)),It=fs.map(n=>{const h=et();return f(new m(Rt,h),ae,n,-.125,0),h}),tt=f(new m(d(new Ce(.2,.22,.14,24)),_({color:"#ffd88a",emissive:"#ffb24a",emissiveIntensity:.35})),ae,0,.07,0);f(new m(d(new x(.05,.05,.2)),_({color:"#5a3d10"})),tt,0,.01,.1);const Nt=ht.map(n=>{const h=et();return{mesh:f(new m(d(new x(...n.size)),h),c,...n.center),mat:h}}),Ot=()=>z({color:K,transparent:!0,opacity:0,blending:Ue,depthWrite:!1}),st=new Map(us.map(([n,h])=>{const[w,T]=[new $(...Oe(n)),new $(...Oe(h))],U=w.clone().lerp(T,.5).add(new $(0,Xs,0)),X=f(new m(d(new is(new as(w,U,T),40,.022,6)),Ot()),c);return[`${n}-${h}`,X]}));await _e();const ot=Os(P,t,K);c.traverse(n=>{n instanceof m&&!n.material.transparent&&(n.castShadow=n.receiveShadow=!0)}),await _e();const Q=new Mt(-1,1,1,-1,1,De*3);let me=e,Te={w:1,h:1},ee=null;const it=()=>{const n=r(me);u.setPixelRatio(n),u.shadowMap.enabled=M.castShadow=me.shadowsAndBloom,me.shadowsAndBloom?ee??=ro(u,c,Q):(ee?.dispose(),ee=null,M.shadow.map?.dispose(),M.shadow.map=null),ee?.resize(Te.w,Te.h,n),ot.setParticles(me.particles)};return it(),I(1),u.extensions.has("KHR_parallel_shader_compile")?await u.compileAsync(c,Q):u.compile(c,Q),await _e(),{standIns:Promise.all(Ee).then(n=>n.filter(h=>h!==null)),resize(n,h){Te={w:n,h},u.setSize(n,h,!1),ee?.resize(n,h,r(me)),Math.abs(Math.log(n/h/k))>.15&&I(n/h)},setQuality(n){me=n,it()},render(n,h,w){const T=n.camera,U=Te.w/Te.h;Q.left=-T.half*U,Q.right=T.half*U,Q.top=T.half,Q.bottom=-T.half;const[X,j,W]=T.target,{back:Z}=hs(T);Q.position.set(X+Z[0]*De,j+Z[1]*De,W+Z[2]*De),Q.lookAt(X,j,W),Q.updateProjectionMatrix();for(const b of h.figures){const A=xe.get(b.island);if(!A)continue;A.position.y=b.hop*Ws,A.rotation.set(-b.reach*Ks,b.yaw,0);const F=1-b.hop*Vs;A.scale.set(F,1+b.hop*$s+Math.sin(w*1.8+b.island*1.3)*.006,F)}he.material.opacity=.25+.75*h.phone,pe.visible=h.message!==null,h.message&&(pe.position.set(...h.message.position),J.scale.setScalar(Math.max(.001,1-h.message.morph)),J.rotation.y=T.azimuth,p.g.scale.setScalar(Math.max(.001,h.message.morph)));const at=b=>b.rotation.set(w*1.3,w*.9,0);at(p.cube),Ne.forEach((b,A)=>{const F=h.stored.find(re=>re.island===A);b.block.g.visible=!!F,b.block.g.position.y=Oe(A)[1]+Math.sin(w*1.6+A)*.03,b.block.cube.rotation.y=w*.6,b.block.glow.scale.setScalar(1.1+.9*(F?.flash??0)),b.leds.forEach((re,Bt)=>{const Ft=.5+.5*Math.sin(w*(3+Bt)+A*2);re.color.copy(Ie).multiplyScalar(.4+.6*Ft).lerp(K,F?Math.max(F.flash,js):0)})}),Ve.forEach((b,A)=>{const F=h.copies.find(re=>re.to===A);b.g.visible=!!F,F&&b.g.position.set(...F.position),at(b.cube)}),ae.rotation.y=h.turntable,tt.rotation.y=(Math.PI/2-h.turntable)*3,It.forEach((b,A)=>b.emissiveIntensity=.55*h.bridge[A]),Nt.forEach((b,A)=>{const{rise:F,lit:re}=h.steps[A];b.mesh.visible=F>.001,b.mesh.position.y=ht[A].center[1]-qs*(1-F),b.mat.emissiveIntensity=.4*re}),st.forEach(b=>b.visible=!1);for(const b of h.threads){const A=st.get(`${b.from}-${b.to}`);A&&(A.visible=b.opacity>0,A.material.opacity=b.opacity)}ot.update(h,w),ee?ee.render():u.render(c,Q)},destroy(){i=!0,ee?.dispose(),l.forEach(n=>n.dispose()),D?.dispose(),u.dispose(),u.getContext().isContextLost()||u.forceContextLoss()}}}function to(a){const e=new we;return e.setAttribute("position",new te(a.position,3)),e.setAttribute("normal",new te(a.normal,3,!0)),e.setAttribute("color",new te(a.color,3)),e.setIndex(new te(a.index,1)),e}function so(a){return a.onBeforeCompile=e=>{e.fragmentShader=e.fragmentShader.replace("#include <emissivemap_fragment>",`#include <emissivemap_fragment>
  totalEmissiveRadiance += diffuseColor.rgb * ${Qs.toFixed(2)};`)},a}function oo(a){const e=Math.round(a>=1?1024:1024*a),t=Math.round(a>=1?1024/a:1024);return q(e,t,s=>{const o=s.createRadialGradient(e/2,t*.3,50,e/2,t*.42,Math.max(e,t)*.9);o.addColorStop(0,"#2d2152"),o.addColorStop(.55,yt),o.addColorStop(1,"#090716"),s.fillStyle=o,s.fillRect(0,0,e,t);const i=ce(11),r=Math.round(380*e*t/(1024*1024));for(let u=0;u<r;u++)s.fillStyle=`rgba(230,225,255,${.12+i()*.5})`,s.beginPath(),s.arc(i()*e,i()*t,i()*1.4,0,Math.PI*2),s.fill()})}function io(){return q(64,64,a=>{const e=a.createRadialGradient(32,32,0,32,32,32);e.addColorStop(0,"rgba(10,6,24,0.55)"),e.addColorStop(1,"rgba(10,6,24,0)"),a.fillStyle=e,a.fillRect(0,0,64,64)})}function ao(a){return q(240,480,e=>{e.fillStyle="#ffffff",e.fillRect(0,0,240,480),e.globalAlpha=.22,e.fillStyle=`#${a.getHexString()}`,e.fillRect(0,56,240,374),e.globalAlpha=1;const t=(s,o,i,r,u,l,d)=>{e.fillStyle=u,e.beginPath(),e.roundRect(s,o,i,r,18),e.fill(),e.fillStyle=l,d.forEach((c,E)=>e.fillRect(s+14,o+14+E*14,c,6))};e.fillStyle=`#${a.getHexString()}`,e.beginPath(),e.arc(40,28,14,0,Math.PI*2),e.fill(),e.fillStyle="#d8d3e2",e.fillRect(64,24,60,8),t(14,84,150,44,"#ffffff","#d8d3e2",[110,70]),t(70,150,156,30,He,"#5d6c8f",[100]),t(14,200,130,44,"#ffffff","#d8d3e2",[96,60]),t(60,360,166,44,He,"#8b9bc0",[120,80]),e.fillStyle="#f1eff5",e.fillRect(0,430,240,50)})}function ro(a,e,t){const s=new Ms(a,new ye(1,1,{type:Ae,samples:4})),o=[new Ss(e,t),new be(new V(1,1),Ye.strength,Ye.radius,Ye.threshold),new xs];return o.forEach(i=>s.addPass(i)),{render:()=>s.render(),resize(i,r,u){s.setPixelRatio(u),s.setSize(i,r)},dispose(){o.forEach(i=>i.dispose()),s.dispose()}}}export{fo as createMemoryLayer};
