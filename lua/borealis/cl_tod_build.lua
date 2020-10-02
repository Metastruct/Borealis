do return end


do
	local sz = 8192 * 8 * 4
	local q = sz * (1 / (8192 * 2 * 4))
	local mesh = Mesh()

	local MeshVertexes = {
		{
			pos = sz * Vector(0.5, 0.5, 0),
			u = q,
			v = q,
			normal = Vector(0, 0, 1)
		},
		{
			pos = sz * Vector(0.5, -0.5, 0),
			u = q,
			v = 0,
			normal = Vector(0, 0, 1)
		},
		{
			pos = sz * Vector(-0.5, -0.5, 0),
			u = 0,
			v = 0,
			normal = Vector(0, 0, 1)
		},
		{
			pos = sz * Vector(-0.5, -0.5, 0),
			u = -q,
			v = -q,
			normal = Vector(0, 0, 1)
		},
		-- Vertex 3
		{
			pos = sz * Vector(-0.5, 0.5, 0),
			u = -q,
			v = 0,
			normal = Vector(0, 0, 1)
		},
		-- Vertex 2
		{
			pos = sz * Vector(0.5, 0.5, 0),
			u = 0,
			v = 0,
			normal = Vector(0, 0, 1)
		}
	}

	-- Vertex 1
	mesh:BuildFromTriangles(MeshVertexes)
	local mat1 = CreateMaterial("asdaasqwsd_" .. os.clock(), "VertexLitGeneric", util.KeyValuesToTable[["Cloud"
{
	"$basetexture" "shadertest/cloud"
	"$cloudalphatexture" "shadertest/cloudalpha"
	"$translucent" 1
	"$alpha" 0.2
	"Proxies"
	{
		"TextureScroll"
		{
			"texturescrollvar" "$baseTextureTransform"
			"texturescrollrate" 0.01
			"texturescrollangle" 0.00
		}
	}
}]])
	local mat2 = CreateMaterial("asdaasqwsd_" .. os.clock(), "VertexLitGeneric", util.KeyValuesToTable[["Cloud"
{
	"$basetexture" "shadertest/cloud"
	"$cloudalphatexture" "shadertest/cloudalpha"
	"$translucent" 1
	"$alpha" 0.2
	"Proxies"
	{
		"TextureScroll"
		{
			"texturescrollvar" "$baseTextureTransform"
			"texturescrollrate" 0.03
			"texturescrollangle" 0.00
		}
	}
}]])

	local t = {
		model = "models/props_junk/sawblade001a.mdl",
		angle = Angle(0, 0, 0),
		pos = here
	}

	local clm
	local off = Vector(0, 0, 2048)

	H.PostDraw2DSkyBox.tod_skyy = function()
		local ep = EyePos()
		if ep.z > off.z then return end
		if ep.z < -13812 then return end
		local now = CurTime()
		--cam.IgnoreZ(false)
		--render.SuppressEngineLighting(true)
		local scale = 1 / 32
		local mat = Matrix()
		local q = 0.1
		mat:Translate(-EyePos() + off + Vector(0, 0, 4024))
		mat:Rotate(Angle(180, 0, 0))
		mat:Scale(Vector(1, 1, 1))
		clm = clm and clm:IsValid() and clm or ClientsideModel(t.model, RENDERGROUP_OTHER)
		render.SetBlend(0)
		render.Model(t, clm)
		render.SetBlend(1)
		render.SetMaterial(mat1)
		cam.Start3D(Vector(0, 0, 0), EyeAngles(), nil, nil, nil, nil, nil, 1024, 8192 * 2 * 2 * 2 * 2)
		cam.PushModelMatrix(mat)
		--render.PushFlashlightMode(true)
		mesh:Draw()
		--render.PopFlashlightMode()
		cam.PopModelMatrix()
		--render.SuppressEngineLighting(false)
		--cam.IgnoreZ(false)
		mat:Translate(Vector(2111, 1400, 475))
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		-- 45 degrees
		mat:Rotate(Angle(0, 45, 0))
		render.SetMaterial(mat2)
		mat:Translate(Vector(-1123, -1223, 900))
		cam.PushModelMatrix(mat)
		--render.PushFlashlightMode(true)
		mesh:Draw()
		--render.PopFlashlightMode()
		cam.PopModelMatrix()
		--render.SuppressEngineLighting(false)
		--cam.IgnoreZ(false)
		mat:Translate(Vector(3123, 4123, 600))
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		cam.End3D()
		render.ClearDepth()
	end
end