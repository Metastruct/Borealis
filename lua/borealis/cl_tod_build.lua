require'skyboxer'

local Tag='buildmovingsky'
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
	local mat1 = CreateMaterial(Tag, "VertexLitGeneric", util.KeyValuesToTable[["Cloud"
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
	local mat2 = CreateMaterial(Tag..'2', "VertexLitGeneric", util.KeyValuesToTable[["Cloud"
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
		pos = Vector(0,0,-4000)
	}

	local clm
	local off = Vector(0, 0, -1048)
	local rotate_1 = Angle(0, 45, 0)
	local rotate_2 = Angle(180, 0, 0)
	local vector_origin = Vector(0, 0, 0)
	local tmp = Vector(0, 0, 0)
	local vec1 = Vector(1, 1, 1)
	local translate_1 = Vector(2111, 1400, 475)
	local translate_2 = Vector(-1123, -1223, 900)
	local translate_3 = Vector(3123, 4123, 600)
	local off2 = Vector(0, 0, 2000)
	local off3 = Vector(0, 0, 4024)
	local mat = Matrix()
	local off_off2 = off + off2
	local ms_build_skyclouds = CreateClientConVar("ms_build_skyclouds_wip","0",true,false,"Enable skybox moving clouds on build",0,1)

	local function PostDraw2DSkyBox()
		
		local ep = EyePos()
		if ep.z > off.z then return end
		if ep.z < -13812 then return end
		if not ms_build_skyclouds:GetBool() then return end
		local now = CurTime()
		
		local scale = 1 / 32
		local q = 0.1
		local trans = EyePos()
		trans:Mul(-1)
		trans:Add(off)
		trans:Add(off3)
		mat:Identity()
		mat:SetTranslation(trans)
		mat:Rotate(rotate_2)
		clm = clm and clm:IsValid() and clm or ClientsideModel(t.model, RENDERGROUP_OTHER)
		clm:SetPos(off_off2)
		render.SetBlend(0)
		render.Model(t, clm)
		render.SetBlend(1)
		render.SetMaterial(mat1)
		
		-- enjoy black magic
		cam.Start3D(vector_origin, EyeAngles(), nil, nil, nil, nil, nil, 256, 8192 * 2 * 2 * 2 * 2)
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		mat:Translate(translate_1)
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		mat:Rotate(rotate_1)
		render.SetMaterial(mat2)
		
		mat:Translate(translate_2)
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		mat:Translate(translate_3)
		cam.PushModelMatrix(mat)
		mesh:Draw()
		cam.PopModelMatrix()
		cam.End3D()
		render.ClearDepth()
	end
	
	-- moon draws before this
	skyboxer.AddHook("d_"..Tag,PostDraw2DSkyBox)
end