module("luci.controller.mihomo_ui", package.seeall)

function index()
	-- 只在订阅管理页存在时挂菜单，避免卸载后留死链
	if not nixio.fs.access("/www/mihomo/index.html") then
		return
	end
	entry({"admin", "services", "mihomo_ui"}, template("mihomo_ui"), _("代理管理"), 60)
end
