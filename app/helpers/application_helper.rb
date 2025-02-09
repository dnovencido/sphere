module ApplicationHelper
    def alert_class(name)
        if name == "notice"
          "text-green-800 rounded-lg bg-green-50 dark:bg-gray-800 dark:text-green-400"
        elsif name == "info"
          "text-blue-800 rounded-lg bg-blue-50 dark:bg-gray-800 dark:text-blue-400"
        else
          "text-red-800 rounded-lg bg-red-50 dark:bg-gray-800 dark:text-red-400"
        end
    end
    def dismiss_button_class(name)
        if name == "notice"
          "bg-green-50 text-green-500 rounded-lg focus:ring-2 focus:ring-green-400 p-1.5 hover:bg-green-200 inline-flex h-8 w-8 dark:bg-gray-800 dark:text-green-400 dark:hover:bg-gray-700"
        elsif name == "info"
          "bg-blue-50 text-blue-500 rounded-lg focus:ring-2 focus:ring-blue-400 p-1.5 hover:bg-blue-200 inline-flex h-8 w-8 dark:bg-gray-800 dark:text-green-400 dark:hover:bg-gray-700"
        else
          "bg-red-50 text-red-500 rounded-lg focus:ring-2 focus:ring-red-400 p-1.5 hover:bg-red-200 inline-flex h-8 w-8 dark:bg-gray-800 dark:text-green-400 dark:hover:bg-gray-700"
        end
    end
end
