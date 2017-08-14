module PublicApi::Es
  class TimeToExitController < PublicController
    def index
      # Part of AHAR
      # Part of system performance
      # Grouped - < 1 weeek, 30 days, 60 days, 90 days, 180 days, 12 months, 18, month
      # What counts as an exit? Completely exited from ES, only look at clients with an exit to non-unknown/refused destination
      # Bed-night for the count, not entry exit
      times_to_exit = [{title: "My first dataset", data: {
        "Jan 2016": 2, "Feb 2016": 43, "Mar 2016": 13, "April 2016": 25, "May 2016": 30,
        "June 2016": 34, "July 2016": 76, "Aug 2016": 3, "Sep 2016": 41, "Oct 2016": 15, "Nov 2016": 0,
        "Dec 2016": 24
      }},
      {title: "My second dataset", data: {
        "Jan 2016": 20, "Feb 2016": 33, "Mar 2016": 13, "April 2016": 25, "May 2016": 20,
        "June 2016": 34, "July 2016": 8, "Aug 2016": 33, "Sep 2016": 1, "Oct 2016": 25, "Nov 2016": 20,
        "Dec 2016": 34
      }}]
      respond_to do |format|
        format.json do
          render json: times_to_exit
        end
      end
    end
  end
end
