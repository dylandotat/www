using Microsoft.AspNetCore.Mvc.RazorPages;

namespace dylan.at.Pages;

public class Index : PageModel
{
    public string UTC { get; set; }
    
    public void OnGet()
    {
        UTC = DateTime.UtcNow.ToString("yyyy-MM-dd");
    }
}