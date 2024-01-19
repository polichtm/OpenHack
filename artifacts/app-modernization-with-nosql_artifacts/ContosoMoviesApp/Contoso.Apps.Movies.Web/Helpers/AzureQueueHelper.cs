using Contoso.Apps.Movies.Data.Models;
using Newtonsoft.Json;
using System;
using System.Configuration;
using System.Threading.Tasks;
using Azure.Storage.Queues;

namespace Contoso.Apps.Movies.Web.Helpers
{
    public class AzureQueueHelper
    {
        QueueClient queueClient;

        public AzureQueueHelper()
        {
            // Retrieve the storage account from a connection string in the web.config file.
            var connectionString = ConfigurationManager.AppSettings["AzureQueueConnectionString"];

            // Retrieve a reference to our queue.
            queueClient = new QueueClient(connectionString, "receiptgenerator");
        }

        /// <summary>
        /// Create a message in our Azure Queue, which will be sent to our Worker Role in order
        /// to generate a Pdf file that gets saved to blob storage, and can be emailed to the client.
        /// </summary>
        /// <param name="orderId"></param>
        /// <returns></returns>
        public async Task QueueReceiptRequest(Order order)
        {
            // Create the queue if it doesn't already exist.
            await queueClient.CreateIfNotExistsAsync();

            if (queueClient.Exists())
            {
                Console.WriteLine("Queue '{0}' Created", queueClient.Name);
            }
            else
            {
                Console.WriteLine("Queue '{0}' Exists", queueClient.Name);
            }

            String jsonOrder = JsonConvert.SerializeObject(order);
            // Create a message and add it to the queue.            
            await queueClient.SendMessageAsync(jsonOrder);
        }
    }
}